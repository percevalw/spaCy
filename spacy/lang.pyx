# cython: profile=True
# cython: embedsignature=True
"""Common classes and utilities across languages.

Provides the main implementation for the spacy tokenizer. Specific languages
subclass the Language class, over-writing the tokenization rules as necessary.
Special-case tokenization rules are read from data/<lang>/tokenization .
"""
from __future__ import unicode_literals

import json
import random
from os import path
import re

from cython.operator cimport preincrement as preinc
from cython.operator cimport dereference as deref
from libc.stdio cimport fopen, fclose, fread, fwrite, FILE

from cymem.cymem cimport Pool
from murmurhash.mrmr cimport hash64
from preshed.maps cimport PreshMap

from .lexeme cimport Lexeme
from .lexeme cimport init as lexeme_init

from . import orth
from . import util
from .util import read_lang_data
from .tokens import Tokens


cdef class Language:
    """Base class for language-specific tokenizers.

    The language's name is used to look up default data-files, found in data/<name.
    """
    def __init__(self, name, user_string_features, user_flag_features):
        self.name = name
        self._mem = Pool()
        self.cache = PreshMap(2 ** 25)
        self.specials = PreshMap(2 ** 16)
        rules, prefix, suffix, infix, lexemes = util.read_lang_data(name)
        self.prefix_re = re.compile(prefix)
        self.suffix_re = re.compile(suffix)
        self.infix_re = re.compile(infix)
        self.lexicon = Lexicon(lexemes)
        self.lexicon.load(path.join(util.DATA_DIR, name, 'lexemes'))
        self.lexicon.strings.load(path.join(util.DATA_DIR, name, 'strings'))
        self._load_special_tokenization(rules)

    cpdef Tokens tokenize(self, unicode string):
        """Tokenize a string.

        The tokenization rules are defined in three places:

        * The data/<lang>/tokenization table, which handles special cases like contractions;
        * The data/<lang>/prefix file, used to build a regex to split off prefixes;
        * The data/<lang>/suffix file, used to build a regex to split off suffixes.

        Args:
            string (unicode): The string to be tokenized. 

        Returns:
            tokens (Tokens): A Tokens object, giving access to a sequence of Lexemes.
        """
        cdef int length = len(string)
        cdef Tokens tokens = Tokens(self.lexicon.strings, length)
        if length == 0:
            return tokens
        cdef int i = 0
        cdef int start = 0
        cdef Py_UNICODE* chars = string
        cdef bint in_ws = Py_UNICODE_ISSPACE(chars[0])
        cdef String span
        for i in range(1, length):
            if Py_UNICODE_ISSPACE(chars[i]) != in_ws:
                if start < i:
                    string_slice(&span, chars, start, i)
                    lexemes = <Lexeme**>self.cache.get(span.key)
                    if lexemes != NULL:
                        tokens.extend(start, lexemes, 0)
                    else: 
                        self._tokenize(tokens, &span, start, i)
                in_ws = not in_ws
                start = i
                if chars[i] == ' ':
                    start += 1
        i += 1
        if start < i:
            string_slice(&span, chars, start, i)
            lexemes = <Lexeme**>self.cache.get(span.key)
            if lexemes != NULL:
                tokens.extend(start, lexemes, 0)
            else: 
                self._tokenize(tokens, &span, start, i)
        return tokens

    cdef int _tokenize(self, Tokens tokens, String* span, int start, int end) except -1:
        cdef vector[Lexeme*] prefixes
        cdef vector[Lexeme*] suffixes
        cdef hash_t orig_key
        cdef int orig_size
        orig_key = span.key
        orig_size = tokens.length
        self._split_affixes(span, &prefixes, &suffixes)
        self._attach_tokens(tokens, start, span, &prefixes, &suffixes)
        self._save_cached(&tokens.lex[orig_size], orig_key, tokens.length - orig_size)

    cdef String* _split_affixes(self, String* string, vector[Lexeme*] *prefixes,
                                vector[Lexeme*] *suffixes) except NULL:
        cdef size_t i
        cdef String prefix
        cdef String suffix
        cdef String minus_pre
        cdef String minus_suf
        cdef size_t last_size = 0
        while string.n != 0 and string.n != last_size:
            last_size = string.n
            pre_len = self._find_prefix(string.chars, string.n)
            if pre_len != 0:
                string_slice(&prefix, string.chars, 0, pre_len)
                string_slice(&minus_pre, string.chars, pre_len, string.n)
                # Check whether we've hit a special-case
                if minus_pre.n >= 1 and self.specials.get(minus_pre.key) != NULL:
                    string[0] = minus_pre
                    prefixes.push_back(self.lexicon.get(&prefix))
                    break
            suf_len = self._find_suffix(string.chars, string.n)
            if suf_len != 0:
                string_slice(&suffix, string.chars, string.n - suf_len, string.n)
                string_slice(&minus_suf, string.chars, 0, string.n - suf_len)
                # Check whether we've hit a special-case
                if minus_suf.n >= 1 and self.specials.get(minus_suf.key) != NULL:
                    string[0] = minus_suf
                    suffixes.push_back(self.lexicon.get(&suffix))
                    break
            if pre_len and suf_len and (pre_len + suf_len) <= string.n:
                string_slice(string, string.chars, pre_len, string.n - suf_len)
                prefixes.push_back(self.lexicon.get(&prefix))
                suffixes.push_back(self.lexicon.get(&suffix))
            elif pre_len:
                string[0] = minus_pre
                prefixes.push_back(self.lexicon.get(&prefix))
            elif suf_len:
                string[0] = minus_suf
                suffixes.push_back(self.lexicon.get(&suffix))
            if self.specials.get(string.key):
                break
        return string

    cdef int _attach_tokens(self, Tokens tokens,
                            int idx, String* string,
                            vector[Lexeme*] *prefixes,
                            vector[Lexeme*] *suffixes) except -1:
        cdef int split
        cdef Lexeme** lexemes
        cdef Lexeme* lexeme
        cdef String span
        if prefixes.size():
            idx = tokens.extend(idx, prefixes.data(), prefixes.size())
        if string.n != 0:

            lexemes = <Lexeme**>self.cache.get(string.key)
            if lexemes != NULL:
                idx = tokens.extend(idx, lexemes, 0)
            else:
                split = self._find_infix(string.chars, string.n)
                if split == 0 or split == -1:
                    idx = tokens.push_back(idx, self.lexicon.get(string))
                else:
                    string_slice(&span, string.chars, 0, split)
                    idx = tokens.push_back(idx, self.lexicon.get(&span))
                    string_slice(&span, string.chars, split, split+1)
                    idx = tokens.push_back(idx, self.lexicon.get(&span))
                    string_slice(&span, string.chars, split + 1, string.n)
                    idx = tokens.push_back(idx, self.lexicon.get(&span))
        cdef vector[Lexeme*].reverse_iterator it = suffixes.rbegin()
        while it != suffixes.rend():
            idx = tokens.push_back(idx, deref(it))
            preinc(it)

    cdef int _save_cached(self, Lexeme** tokens, hash_t key, int n) except -1:
        lexemes = <Lexeme**>self._mem.alloc(n + 1, sizeof(Lexeme**))
        cdef int i
        for i in range(n):
            lexemes[i] = tokens[i]
        lexemes[i + 1] = NULL
        self.cache.set(key, lexemes)

    cdef int _find_infix(self, Py_UNICODE* chars, size_t length) except -1:
        cdef unicode string = chars[:length]
        match = self.infix_re.search(string)
        return match.start() if match is not None else 0
    
    cdef int _find_prefix(self, Py_UNICODE* chars, size_t length) except -1:
        cdef unicode string = chars[:length]
        match = self.prefix_re.search(string)
        return (match.end() - match.start()) if match is not None else 0

    cdef int _find_suffix(self, Py_UNICODE* chars, size_t length) except -1:
        cdef unicode string = chars[:length]
        match = self.suffix_re.search(string)
        return (match.end() - match.start()) if match is not None else 0

    def _load_special_tokenization(self, token_rules):
        '''Load special-case tokenization rules.

        Loads special-case tokenization rules into the Language.cache cache,
        read from data/<lang>/tokenization . The special cases are loaded before
        any language data is tokenized, giving these priority.  For instance,
        the English tokenization rules map "ain't" to ["are", "not"].

        Args:
            token_rules (list): A list of (chunk, tokens) pairs, where chunk is
                a string and tokens is a list of strings.
        '''
        cdef Lexeme** lexemes
        cdef hash_t hashed
        cdef String string
        for uni_string, substrings in token_rules:
            lexemes = <Lexeme**>self._mem.alloc(len(substrings) + 1, sizeof(Lexeme*))
            for i, substring in enumerate(substrings):
                string_from_unicode(&string, substring)
                lexemes[i] = <Lexeme*>self.lexicon.get(&string)
            lexemes[i + 1] = NULL
            string_from_unicode(&string, uni_string)
            self.specials.set(string.key, lexemes)
            self.cache.set(string.key, lexemes)


cdef class Lexicon:
    def __init__(self, lexemes):
        self.mem = Pool()
        self._dict = PreshMap(2 ** 20)
        self.strings = StringStore()
        self.size = 1
        cdef String string
        cdef Lexeme* lexeme
        for py_string, lexeme_dict in lexemes.iteritems():
            string_from_unicode(&string, py_string)
            lexeme = <Lexeme*>self.mem.alloc(1, sizeof(Lexeme))
            lexeme[0] = lexeme_init(string.chars[:string.n], string.key, self.size,
                                    self.strings, lexeme_dict)
            self._dict.set(lexeme.hash, lexeme)
            self.lexemes.push_back(lexeme)
            self.size += 1

    def set(self, unicode py_string, dict lexeme_dict):
        cdef String string
        string_from_unicode(&string, py_string)
        cdef Lexeme* lex = self.get(&string)
        lex[0] = lexeme_init(string.chars[:string.n], string.key, lex.i,
                             self.strings, lexeme_dict)

    cdef Lexeme* get(self, String* string) except NULL:
        cdef Lexeme* lex
        lex = <Lexeme*>self._dict.get(string.key)
        if lex != NULL:
            return lex
        lex = <Lexeme*>self.mem.alloc(sizeof(Lexeme), 1)
        lex[0] = lexeme_init(string.chars[:string.n], string.key, self.size,
                             self.strings, {})
        self._dict.set(lex.hash, lex)
        self.lexemes.push_back(lex)
        self.size += 1
        return lex

    cpdef Lexeme lookup(self, unicode uni_string):
        """Retrieve (or create, if not found) a Lexeme for a string, and return it.
    
        Args
            string (unicode):  The string to be looked up. Must be unicode, not bytes.

        Returns:
            lexeme (Lexeme): A reference to a lexical type.
        """
        cdef String string
        string_from_unicode(&string, uni_string)
        cdef Lexeme* lexeme = self.get(&string)
        return lexeme[0]

    def dump(self, loc):
        if path.exists(loc):
            assert not path.isdir(loc)
        cdef bytes bytes_loc = loc.encode('utf8') if type(loc) == unicode else loc
        cdef FILE* fp = fopen(<char*>bytes_loc, 'wb')
        assert fp != NULL
        cdef size_t st
        for i in range(self.size-1):
            st = fwrite(self.lexemes[i], sizeof(Lexeme), 1, fp)
            assert st == 1
        st = fclose(fp)
        assert st == 0

    def load(self, loc):
        assert path.exists(loc)
        cdef bytes bytes_loc = loc.encode('utf8') if type(loc) == unicode else loc
        cdef FILE* fp = fopen(<char*>bytes_loc, 'rb')
        assert fp != NULL
        cdef size_t st
        cdef Lexeme* lexeme
        i = 0
        while True:
            lexeme = <Lexeme*>self.mem.alloc(sizeof(Lexeme), 1)
            st = fread(lexeme, sizeof(Lexeme), 1, fp)
            if st != 1:
                break
            self.lexemes.push_back(lexeme)
            self._dict.set(lexeme.hash, lexeme)
            i += 1
        print "Load %d lexemes" % i
        fclose(fp)
        

cdef void string_from_unicode(String* s, unicode uni):
    cdef Py_UNICODE* c_uni = <Py_UNICODE*>uni
    string_slice(s, c_uni, 0, len(uni))


cdef inline void string_slice(String* s, Py_UNICODE* chars, int start, int end) nogil:
    s.chars = &chars[start]
    s.n = end - start
    s.key = hash64(s.chars, s.n * sizeof(Py_UNICODE), 0)

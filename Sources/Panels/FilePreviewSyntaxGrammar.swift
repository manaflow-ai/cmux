import Foundation

/// Per-language description that drives the shared tokenizer. The same scanner
/// (``FilePreviewSyntaxTokenizer``) handles every supported language; only these
/// parameters differ.
struct FilePreviewSyntaxGrammar: Sendable {
    var lineComments: [String]
    var blockComment: (open: String, close: String)?
    var stringDelimiters: [Unicode.Scalar]
    var supportsTripleQuotedStrings: Bool
    var allowsDollarInIdentifiers: Bool
    var usesAtDecorators: Bool
    var usesPreprocessorHash: Bool
    var keywords: Set<String>
    var types: Set<String>
    var detectFunctionCalls: Bool

    init(
        lineComments: [String] = [],
        blockComment: (open: String, close: String)? = nil,
        stringDelimiters: [Unicode.Scalar] = ["\""],
        supportsTripleQuotedStrings: Bool = false,
        allowsDollarInIdentifiers: Bool = false,
        usesAtDecorators: Bool = false,
        usesPreprocessorHash: Bool = false,
        keywords: Set<String> = [],
        types: Set<String> = [],
        detectFunctionCalls: Bool = true
    ) {
        self.lineComments = lineComments
        self.blockComment = blockComment
        self.stringDelimiters = stringDelimiters
        self.supportsTripleQuotedStrings = supportsTripleQuotedStrings
        self.allowsDollarInIdentifiers = allowsDollarInIdentifiers
        self.usesAtDecorators = usesAtDecorators
        self.usesPreprocessorHash = usesPreprocessorHash
        self.keywords = keywords
        self.types = types
        self.detectFunctionCalls = detectFunctionCalls
    }

    static func grammar(for language: FilePreviewSyntaxLanguage) -> FilePreviewSyntaxGrammar {
        switch language {
        case .swift:
            return FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\""],
                supportsTripleQuotedStrings: true,
                usesAtDecorators: true,
                keywords: FilePreviewSyntaxKeywords.swift,
                types: FilePreviewSyntaxTypes.swift
            )
        case .cFamily:
            return FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                usesPreprocessorHash: true,
                keywords: FilePreviewSyntaxKeywords.c,
                types: FilePreviewSyntaxTypes.c
            )
        case .cpp:
            return FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                usesPreprocessorHash: true,
                keywords: FilePreviewSyntaxKeywords.cpp,
                types: FilePreviewSyntaxTypes.c
            )
        case .objc:
            return FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                usesAtDecorators: true,
                usesPreprocessorHash: true,
                keywords: FilePreviewSyntaxKeywords.objc,
                types: FilePreviewSyntaxTypes.c
            )
        case .java:
            return FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                supportsTripleQuotedStrings: true,
                usesAtDecorators: true,
                keywords: FilePreviewSyntaxKeywords.java,
                types: FilePreviewSyntaxTypes.java
            )
        case .kotlin:
            return FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                supportsTripleQuotedStrings: true,
                usesAtDecorators: true,
                keywords: FilePreviewSyntaxKeywords.kotlin,
                types: FilePreviewSyntaxTypes.java
            )
        case .csharp:
            return FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                usesPreprocessorHash: true,
                keywords: FilePreviewSyntaxKeywords.csharp,
                types: FilePreviewSyntaxTypes.csharp
            )
        case .javascript:
            return FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'", "`"],
                allowsDollarInIdentifiers: true,
                usesAtDecorators: true,
                keywords: FilePreviewSyntaxKeywords.javascript,
                types: FilePreviewSyntaxTypes.javascript
            )
        case .typescript:
            return FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'", "`"],
                allowsDollarInIdentifiers: true,
                usesAtDecorators: true,
                keywords: FilePreviewSyntaxKeywords.typescript,
                types: FilePreviewSyntaxTypes.typescript
            )
        case .python:
            return FilePreviewSyntaxGrammar(
                lineComments: ["#"],
                blockComment: nil,
                stringDelimiters: ["\"", "'"],
                supportsTripleQuotedStrings: true,
                usesAtDecorators: true,
                keywords: FilePreviewSyntaxKeywords.python,
                types: FilePreviewSyntaxTypes.python
            )
        case .ruby:
            return FilePreviewSyntaxGrammar(
                lineComments: ["#"],
                blockComment: nil,
                stringDelimiters: ["\"", "'"],
                keywords: FilePreviewSyntaxKeywords.ruby,
                types: FilePreviewSyntaxTypes.ruby
            )
        case .go:
            return FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'", "`"],
                keywords: FilePreviewSyntaxKeywords.go,
                types: FilePreviewSyntaxTypes.go
            )
        case .rust:
            return FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                usesAtDecorators: true,
                keywords: FilePreviewSyntaxKeywords.rust,
                types: FilePreviewSyntaxTypes.rust
            )
        case .php:
            return FilePreviewSyntaxGrammar(
                lineComments: ["//", "#"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                allowsDollarInIdentifiers: true,
                keywords: FilePreviewSyntaxKeywords.php,
                types: FilePreviewSyntaxTypes.php
            )
        case .shell:
            return FilePreviewSyntaxGrammar(
                lineComments: ["#"],
                blockComment: nil,
                stringDelimiters: ["\"", "'"],
                allowsDollarInIdentifiers: true,
                keywords: FilePreviewSyntaxKeywords.shell,
                types: [],
                detectFunctionCalls: false
            )
        case .sql:
            return FilePreviewSyntaxGrammar(
                lineComments: ["--"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["'", "\""],
                keywords: FilePreviewSyntaxKeywords.sql,
                types: FilePreviewSyntaxTypes.sql,
                detectFunctionCalls: false
            )
        case .css:
            return FilePreviewSyntaxGrammar(
                lineComments: [],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                usesAtDecorators: true,
                keywords: [],
                types: [],
                detectFunctionCalls: true
            )
        case .json:
            return FilePreviewSyntaxGrammar(
                lineComments: [],
                blockComment: nil,
                stringDelimiters: ["\""],
                keywords: ["true", "false", "null"],
                types: [],
                detectFunctionCalls: false
            )
        case .yaml:
            return FilePreviewSyntaxGrammar(
                lineComments: ["#"],
                blockComment: nil,
                stringDelimiters: ["\"", "'"],
                keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                types: [],
                detectFunctionCalls: false
            )
        case .toml, .ini:
            return FilePreviewSyntaxGrammar(
                lineComments: ["#", ";"],
                blockComment: nil,
                stringDelimiters: ["\"", "'"],
                keywords: ["true", "false"],
                types: [],
                detectFunctionCalls: false
            )
        }
    }
}

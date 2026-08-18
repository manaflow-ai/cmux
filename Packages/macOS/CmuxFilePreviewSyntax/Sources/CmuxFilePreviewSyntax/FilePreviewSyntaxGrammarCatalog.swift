/// Builds scanner parameters from the package's keyword and type catalogs.
struct FilePreviewSyntaxGrammarCatalog: Sendable {
    private let keywords = FilePreviewSyntaxKeywordCatalog()
    private let types = FilePreviewSyntaxTypeCatalog()

    func grammar(for language: FilePreviewSyntaxLanguage) -> FilePreviewSyntaxGrammar {
        switch language {
        case .swift:
            FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                tripleQuotedStringDelimiters: ["\""],
                usesAtDecorators: true,
                keywords: keywords.keywords(for: language),
                types: types.types(for: language)
            )
        case .cFamily, .cpp:
            FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                usesPreprocessorHash: true,
                keywords: keywords.keywords(for: language),
                types: types.types(for: language)
            )
        case .objc:
            FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                usesAtDecorators: true,
                usesPreprocessorHash: true,
                keywords: keywords.keywords(for: language),
                types: types.types(for: language)
            )
        case .java, .kotlin:
            FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                tripleQuotedStringDelimiters: ["\""],
                usesAtDecorators: true,
                keywords: keywords.keywords(for: language),
                types: types.types(for: language)
            )
        case .csharp:
            FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                usesPreprocessorHash: true,
                keywords: keywords.keywords(for: language),
                types: types.types(for: language)
            )
        case .javascript, .typescript:
            FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'", "`"],
                multilineStringDelimiters: ["`"],
                allowsDollarInIdentifiers: true,
                usesAtDecorators: true,
                keywords: keywords.keywords(for: language),
                types: types.types(for: language)
            )
        case .python:
            FilePreviewSyntaxGrammar(
                lineComments: ["#"],
                stringDelimiters: ["\"", "'"],
                tripleQuotedStringDelimiters: ["\"", "'"],
                usesAtDecorators: true,
                keywords: keywords.keywords(for: language),
                types: types.types(for: language)
            )
        case .ruby:
            FilePreviewSyntaxGrammar(
                lineComments: ["#"],
                stringDelimiters: ["\"", "'"],
                keywords: keywords.keywords(for: language),
                types: types.types(for: language)
            )
        case .go:
            FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'", "`"],
                multilineStringDelimiters: ["`"],
                keywords: keywords.keywords(for: language),
                types: types.types(for: language)
            )
        case .rust:
            FilePreviewSyntaxGrammar(
                lineComments: ["//"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\""],
                usesAtDecorators: true,
                keywords: keywords.keywords(for: language),
                types: types.types(for: language)
            )
        case .php:
            FilePreviewSyntaxGrammar(
                lineComments: ["//", "#"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                allowsDollarInIdentifiers: true,
                keywords: keywords.keywords(for: language),
                types: types.types(for: language)
            )
        case .shell:
            FilePreviewSyntaxGrammar(
                lineComments: ["#"],
                stringDelimiters: ["\"", "'"],
                allowsDollarInIdentifiers: true,
                keywords: keywords.keywords(for: language),
                detectsFunctionCalls: false
            )
        case .sql:
            FilePreviewSyntaxGrammar(
                lineComments: ["--"],
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                identifiersAreCaseInsensitive: true,
                keywords: keywords.keywords(for: language),
                types: types.types(for: language),
                detectsFunctionCalls: false
            )
        case .css:
            FilePreviewSyntaxGrammar(
                blockComment: (open: "/*", close: "*/"),
                stringDelimiters: ["\"", "'"],
                usesAtDecorators: true
            )
        case .json:
            FilePreviewSyntaxGrammar(
                keywords: keywords.keywords(for: language),
                detectsFunctionCalls: false
            )
        case .yaml:
            FilePreviewSyntaxGrammar(
                lineComments: ["#"],
                stringDelimiters: ["\"", "'"],
                identifiersAreCaseInsensitive: true,
                keywords: keywords.keywords(for: language),
                detectsFunctionCalls: false
            )
        case .toml, .ini:
            FilePreviewSyntaxGrammar(
                lineComments: ["#", ";"],
                stringDelimiters: ["\"", "'"],
                identifiersAreCaseInsensitive: true,
                keywords: keywords.keywords(for: language),
                detectsFunctionCalls: false
            )
        }
    }
}

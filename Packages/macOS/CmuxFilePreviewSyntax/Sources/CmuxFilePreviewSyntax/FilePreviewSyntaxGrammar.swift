/// Per-language scanner parameters consumed by ``FilePreviewSyntaxHighlighter``.
struct FilePreviewSyntaxGrammar: Sendable {
    let lineComments: [String]
    let blockComment: (open: String, close: String)?
    let stringDelimiters: Set<Unicode.Scalar>
    let tripleQuotedStringDelimiters: Set<Unicode.Scalar>
    let multilineStringDelimiters: Set<Unicode.Scalar>
    let allowsDollarInIdentifiers: Bool
    let usesAtDecorators: Bool
    let usesPreprocessorHash: Bool
    let identifiersAreCaseInsensitive: Bool
    let keywords: Set<String>
    let types: Set<String>
    let detectsFunctionCalls: Bool

    init(
        lineComments: [String] = [],
        blockComment: (open: String, close: String)? = nil,
        stringDelimiters: Set<Unicode.Scalar> = ["\""],
        tripleQuotedStringDelimiters: Set<Unicode.Scalar> = [],
        multilineStringDelimiters: Set<Unicode.Scalar> = [],
        allowsDollarInIdentifiers: Bool = false,
        usesAtDecorators: Bool = false,
        usesPreprocessorHash: Bool = false,
        identifiersAreCaseInsensitive: Bool = false,
        keywords: Set<String> = [],
        types: Set<String> = [],
        detectsFunctionCalls: Bool = true
    ) {
        self.lineComments = lineComments
        self.blockComment = blockComment
        self.stringDelimiters = stringDelimiters
        self.tripleQuotedStringDelimiters = tripleQuotedStringDelimiters
        self.multilineStringDelimiters = multilineStringDelimiters
        self.allowsDollarInIdentifiers = allowsDollarInIdentifiers
        self.usesAtDecorators = usesAtDecorators
        self.usesPreprocessorHash = usesPreprocessorHash
        self.identifiersAreCaseInsensitive = identifiersAreCaseInsensitive
        self.keywords = keywords
        self.types = types
        self.detectsFunctionCalls = detectsFunctionCalls
    }
}

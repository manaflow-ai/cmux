/// Stateful scanner used for one bounded syntax-highlighting pass.
struct FilePreviewSyntaxScanner {
    private var cursor: FilePreviewSyntaxCursor
    private let grammar: FilePreviewSyntaxGrammar
    private let maximumTokenCount: Int
    private let lineCommentPatterns: [[Unicode.Scalar]]
    private let blockCommentOpen: [Unicode.Scalar]?
    private let blockCommentClose: [Unicode.Scalar]?
    private var tokens: [FilePreviewSyntaxToken] = []
    private var isAtLineStart = true

    init(
        source: String,
        grammar: FilePreviewSyntaxGrammar,
        maximumTokenCount: Int
    ) {
        cursor = FilePreviewSyntaxCursor(source: source)
        self.grammar = grammar
        self.maximumTokenCount = maximumTokenCount
        lineCommentPatterns = grammar.lineComments.map { Array($0.unicodeScalars) }
        blockCommentOpen = grammar.blockComment.map { Array($0.open.unicodeScalars) }
        blockCommentClose = grammar.blockComment.map { Array($0.close.unicodeScalars) }
    }

    mutating func scan() -> FilePreviewSyntaxHighlightResult {
        while let scalar = cursor.current {
            guard !cursor.wasCancelled else { return cancelledResult }

            if scalar == "\n" || scalar == "\r" {
                cursor.advance()
                isAtLineStart = true
            } else if Self.isWhitespace(scalar) {
                cursor.advance()
            } else if let pattern = lineCommentPatterns.first(where: cursor.matches) {
                guard scanLineComment(pattern) else { return interruptedResult }
            } else if let open = blockCommentOpen,
                      let close = blockCommentClose,
                      cursor.matches(open) {
                guard scanBlockComment(open: open, close: close) else {
                    return interruptedResult
                }
            } else if grammar.stringDelimiters.contains(scalar) {
                guard scanString(delimiter: scalar) else {
                    return interruptedResult
                }
            } else if Self.isDigit(scalar)
                        || (scalar == "." && cursor.peek(1).map(Self.isDigit) == true) {
                guard scanNumber() else { return interruptedResult }
            } else if grammar.usesAtDecorators,
                      scalar == "@",
                      cursor.peek(1).map(Self.isIdentifierStart) == true {
                guard scanAttribute() else { return interruptedResult }
            } else if grammar.usesPreprocessorHash, isAtLineStart, scalar == "#" {
                guard scanPreprocessorDirective() else { return interruptedResult }
            } else if Self.isIdentifierStart(scalar) {
                guard scanIdentifier() else { return interruptedResult }
            } else {
                cursor.advance()
                isAtLineStart = false
            }
        }

        guard !cursor.wasCancelled, !Task.isCancelled else { return cancelledResult }
        return FilePreviewSyntaxHighlightResult(
            tokens: tokens,
            didExceedTokenLimit: false,
            wasCancelled: false
        )
    }

    private mutating func scanLineComment(_ pattern: [Unicode.Scalar]) -> Bool {
        let start = cursor.utf16Offset
        cursor.advance(pattern.count)
        cursor.advanceToEndOfLine()
        isAtLineStart = false
        return appendToken(from: start, kind: .comment)
    }

    private mutating func scanBlockComment(
        open: [Unicode.Scalar],
        close: [Unicode.Scalar]
    ) -> Bool {
        let start = cursor.utf16Offset
        cursor.advance(open.count)
        cursor.advanceUntilMatch(close)
        guard !Task.isCancelled else { return false }
        isAtLineStart = false
        return appendToken(from: start, kind: .comment)
    }

    private mutating func scanString(delimiter: Unicode.Scalar) -> Bool {
        let start = cursor.utf16Offset
        let triple = [delimiter, delimiter, delimiter]
        if grammar.tripleQuotedStringDelimiters.contains(delimiter),
           cursor.matches(triple) {
            cursor.advance(triple.count)
            cursor.advanceUntilMatch(triple)
        } else {
            let allowsNewlines = grammar.multilineStringDelimiters.contains(delimiter)
            cursor.advance()
            while let scalar = cursor.current, !Task.isCancelled {
                if scalar == "\\" {
                    cursor.advance()
                    cursor.advance()
                } else if scalar == delimiter {
                    cursor.advance()
                    break
                } else if !allowsNewlines && (scalar == "\n" || scalar == "\r") {
                    break
                } else {
                    cursor.advance()
                }
            }
        }
        guard !Task.isCancelled else { return false }
        isAtLineStart = false
        return appendToken(from: start, kind: .string)
    }

    private mutating func scanNumber() -> Bool {
        let start = cursor.utf16Offset
        cursor.advanceWhile(Self.isNumberContinuation)
        isAtLineStart = false
        return appendToken(from: start, kind: .number)
    }

    private mutating func scanAttribute() -> Bool {
        let start = cursor.utf16Offset
        cursor.advance()
        cursor.advanceWhile {
            Self.isIdentifierContinuation(
                $0,
                allowsDollar: grammar.allowsDollarInIdentifiers
            )
        }
        isAtLineStart = false
        return appendToken(from: start, kind: .attribute)
    }

    private mutating func scanPreprocessorDirective() -> Bool {
        let start = cursor.utf16Offset
        cursor.advance()
        cursor.advanceWhile {
            Self.isIdentifierContinuation($0, allowsDollar: false)
        }
        isAtLineStart = false
        return appendToken(from: start, kind: .attribute)
    }

    private mutating func scanIdentifier() -> Bool {
        let start = cursor.utf16Offset
        let identifier = cursor.consumeIdentifier {
            Self.isIdentifierContinuation(
                $0,
                allowsDollar: grammar.allowsDollarInIdentifiers
            )
        }
        let catalogIdentifier = grammar.identifiersAreCaseInsensitive
            ? identifier.lowercased()
            : identifier
        let kind: FilePreviewSyntaxTokenKind?
        if grammar.keywords.contains(catalogIdentifier) {
            kind = .keyword
        } else if grammar.types.contains(catalogIdentifier) {
            kind = .type
        } else if grammar.detectsFunctionCalls, cursor.nextNonSpaceScalar() == "(" {
            kind = .function
        } else {
            kind = nil
        }
        isAtLineStart = false
        guard let kind else { return true }
        return appendToken(from: start, kind: kind)
    }

    private mutating func appendToken(
        from start: Int,
        kind: FilePreviewSyntaxTokenKind
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        guard tokens.count < maximumTokenCount else { return false }
        tokens.append(
            FilePreviewSyntaxToken(
                utf16Range: cursor.range(from: start),
                kind: kind
            )
        )
        return true
    }

    private var overflowResult: FilePreviewSyntaxHighlightResult {
        FilePreviewSyntaxHighlightResult(
            tokens: [],
            didExceedTokenLimit: true,
            wasCancelled: false
        )
    }

    private var cancelledResult: FilePreviewSyntaxHighlightResult {
        FilePreviewSyntaxHighlightResult(
            tokens: [],
            didExceedTokenLimit: false,
            wasCancelled: true
        )
    }

    private var interruptedResult: FilePreviewSyntaxHighlightResult {
        Task.isCancelled ? cancelledResult : overflowResult
    }

    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar.value == 0x0B || scalar.value == 0x0C
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar >= "0" && scalar <= "9"
    }

    private static func isNumberContinuation(_ scalar: Unicode.Scalar) -> Bool {
        isDigit(scalar)
            || (scalar >= "a" && scalar <= "z")
            || (scalar >= "A" && scalar <= "Z")
            || scalar == "."
            || scalar == "_"
    }

    private static func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z")
            || (scalar >= "A" && scalar <= "Z")
            || scalar == "_"
            || scalar.value > 0x7F
    }

    private static func isIdentifierContinuation(
        _ scalar: Unicode.Scalar,
        allowsDollar: Bool
    ) -> Bool {
        isIdentifierStart(scalar) || isDigit(scalar) || (allowsDollar && scalar == "$")
    }
}

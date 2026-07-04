import Foundation

/// Shared, dependency-free scanner that turns source text into colored token
/// ranges. Pure value-in / value-out so it runs off the main thread and is
/// straightforward to unit test.
enum FilePreviewSyntaxTokenizer {
    static func tokens(in source: String, language: FilePreviewSyntaxLanguage) -> [FilePreviewSyntaxToken] {
        tokens(in: source, grammar: language.grammar)
    }

    static func tokens(in source: String, grammar: FilePreviewSyntaxGrammar) -> [FilePreviewSyntaxToken] {
        var cursor = FilePreviewSyntaxCursor(source: source)
        var tokens: [FilePreviewSyntaxToken] = []
        let lineCommentPatterns = grammar.lineComments.map { Array($0.unicodeScalars) }
        let blockOpen = grammar.blockComment.map { Array($0.open.unicodeScalars) }
        let blockClose = grammar.blockComment.map { Array($0.close.unicodeScalars) }
        var atLineStart = true

        while let scalar = cursor.current {
            if Task.isCancelled { return tokens }
            if scalar == "\n" || scalar == "\r" {
                cursor.advance()
                atLineStart = true
                continue
            }
            if isWhitespace(scalar) {
                cursor.advance()
                continue
            }

            // Line comments.
            if let pattern = lineCommentPatterns.first(where: { cursor.matches($0) }) {
                let start = cursor.utf16Offset
                cursor.advance(pattern.count)
                cursor.advanceToEndOfLine()
                tokens.append(FilePreviewSyntaxToken(range: cursor.range(from: start), kind: .comment))
                atLineStart = false
                continue
            }

            // Block comments.
            if let open = blockOpen, let close = blockClose, cursor.matches(open) {
                let start = cursor.utf16Offset
                cursor.advance(open.count)
                cursor.advanceUntilMatch(close)
                tokens.append(FilePreviewSyntaxToken(range: cursor.range(from: start), kind: .comment))
                atLineStart = false
                continue
            }

            // Strings (triple-quoted first so they win over the single form).
            if grammar.stringDelimiters.contains(scalar) {
                let token = scanString(&cursor, delimiter: scalar, grammar: grammar)
                tokens.append(token)
                atLineStart = false
                continue
            }

            // Numbers.
            if isDigit(scalar) || (scalar == "." && cursor.peek(1).map(isDigit) == true) {
                let start = cursor.utf16Offset
                cursor.advanceWhile { isNumberContinuation($0) }
                tokens.append(FilePreviewSyntaxToken(range: cursor.range(from: start), kind: .number))
                atLineStart = false
                continue
            }

            // Decorators / annotations (@Foo).
            if grammar.usesAtDecorators, scalar == "@", cursor.peek(1).map(isIdentifierStart) == true {
                let start = cursor.utf16Offset
                cursor.advance()
                cursor.advanceWhile { isIdentifierContinuation($0, allowsDollar: grammar.allowsDollarInIdentifiers) }
                tokens.append(FilePreviewSyntaxToken(range: cursor.range(from: start), kind: .attribute))
                atLineStart = false
                continue
            }

            // C-family preprocessor directives (#include) at line start.
            if grammar.usesPreprocessorHash, atLineStart, scalar == "#" {
                let start = cursor.utf16Offset
                cursor.advance()
                cursor.advanceWhile { isIdentifierContinuation($0, allowsDollar: false) }
                tokens.append(FilePreviewSyntaxToken(range: cursor.range(from: start), kind: .attribute))
                atLineStart = false
                continue
            }

            // Identifiers / keywords / types / function calls.
            if isIdentifierStart(scalar) {
                let start = cursor.utf16Offset
                let text = cursor.consumeIdentifier { scalar in
                    isIdentifierContinuation(scalar, allowsDollar: grammar.allowsDollarInIdentifiers)
                }
                if grammar.keywords.contains(text) {
                    tokens.append(FilePreviewSyntaxToken(range: cursor.range(from: start), kind: .keyword))
                } else if grammar.types.contains(text) {
                    tokens.append(FilePreviewSyntaxToken(range: cursor.range(from: start), kind: .type))
                } else if grammar.detectFunctionCalls, cursor.nextNonSpaceScalar() == "(" {
                    tokens.append(FilePreviewSyntaxToken(range: cursor.range(from: start), kind: .function))
                }
                atLineStart = false
                continue
            }

            // Operators / punctuation: left at the editor's base color.
            cursor.advance()
            atLineStart = false
        }

        return tokens
    }

    private static func scanString(
        _ cursor: inout FilePreviewSyntaxCursor,
        delimiter: Unicode.Scalar,
        grammar: FilePreviewSyntaxGrammar
    ) -> FilePreviewSyntaxToken {
        let start = cursor.utf16Offset
        let triple: [Unicode.Scalar] = [delimiter, delimiter, delimiter]
        if grammar.supportsTripleQuotedStrings, cursor.matches(triple) {
            cursor.advance(3)
            cursor.advanceUntilMatch(triple)
            return FilePreviewSyntaxToken(range: cursor.range(from: start), kind: .string)
        }

        cursor.advance() // opening delimiter
        while let scalar = cursor.current {
            if Task.isCancelled { break }
            if scalar == "\\" {
                cursor.advance()
                cursor.advance() // escaped scalar
                continue
            }
            if scalar == delimiter {
                cursor.advance()
                break
            }
            if scalar == "\n" || scalar == "\r" {
                break // unterminated single-line string
            }
            cursor.advance()
        }
        return FilePreviewSyntaxToken(range: cursor.range(from: start), kind: .string)
    }

    // MARK: - Scalar classification

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

    private static func isIdentifierContinuation(_ scalar: Unicode.Scalar, allowsDollar: Bool) -> Bool {
        isIdentifierStart(scalar) || isDigit(scalar) || (allowsDollar && scalar == "$")
    }
}

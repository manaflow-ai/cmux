import Foundation

/// Locates here-document body and terminator lines so the task command
/// composer can treat them as data instead of shell syntax.
struct MobileTaskHereDocumentParser {
    struct Body {
        let range: Range<String.Index>
        let permitsEnvironmentExpansion: Bool
    }

    private enum Quote {
        case unquoted
        case single
        case double
    }

    private struct Descriptor {
        let delimiter: String
        let stripsLeadingTabs: Bool
        let permitsEnvironmentExpansion: Bool
    }

    private struct LexicalState {
        private(set) var quote = Quote.unquoted
        private(set) var escaped = false
        private(set) var inComment = false
        private var atWordBoundary = true

        func startsComment(with character: Character) -> Bool {
            quote == .unquoted && !escaped && character == "#" && atWordBoundary
        }

        mutating func beginComment() {
            inComment = true
        }

        mutating func consume(_ character: Character) {
            if inComment {
                if character == "\n" {
                    inComment = false
                    atWordBoundary = true
                }
                return
            }
            if escaped {
                escaped = false
                atWordBoundary = false
                return
            }
            switch (quote, character) {
            case (.unquoted, "\\"), (.double, "\\"):
                escaped = true
            case (.unquoted, "'"):
                quote = .single
                atWordBoundary = false
            case (.unquoted, "\""):
                quote = .double
                atWordBoundary = false
            case (.single, "'"):
                quote = .unquoted
            case (.double, "\""):
                quote = .unquoted
            case (.unquoted, " "), (.unquoted, "\t"), (.unquoted, "\r"), (.unquoted, "\n"):
                atWordBoundary = true
            case (.unquoted, ";"), (.unquoted, "|"), (.unquoted, "&"),
                 (.unquoted, "("), (.unquoted, ")"), (.unquoted, "<"), (.unquoted, ">"):
                atWordBoundary = true
            default:
                if quote == .unquoted {
                    atWordBoundary = false
                }
            }
        }
    }

    func bodies(in command: String) -> [Body] {
        var bodies: [Body] = []
        var pending: [Descriptor] = []
        var lexicalState = LexicalState()
        var readingBodies = false
        var lineStart = command.startIndex

        while lineStart < command.endIndex {
            let newline = command[lineStart...].firstIndex(of: "\n")
            let contentEnd = newline ?? command.endIndex
            let lineEnd = newline.map { command.index(after: $0) } ?? command.endIndex

            if readingBodies, let descriptor = pending.first {
                var candidate = String(command[lineStart..<contentEnd])
                if candidate.last == "\r" { candidate.removeLast() }
                if descriptor.stripsLeadingTabs {
                    candidate.removeFirst(candidate.prefix(while: { $0 == "\t" }).count)
                }
                let isTerminator = candidate == descriptor.delimiter
                bodies.append(Body(
                    range: lineStart..<lineEnd,
                    permitsEnvironmentExpansion: descriptor.permitsEnvironmentExpansion && !isTerminator
                ))
                if isTerminator {
                    pending.removeFirst()
                    readingBodies = !pending.isEmpty
                }
            } else {
                scanDescriptors(
                    in: command,
                    range: lineStart..<contentEnd,
                    lexicalState: &lexicalState,
                    pending: &pending
                )
                readingBodies = !pending.isEmpty
                    && !lexicalState.escaped
                    && lexicalState.quote == .unquoted
            }

            if newline != nil { lexicalState.consume("\n") }
            lineStart = lineEnd
        }
        return bodies
    }

    private func scanDescriptors(
        in command: String,
        range: Range<String.Index>,
        lexicalState: inout LexicalState,
        pending: inout [Descriptor]
    ) {
        var index = range.lowerBound
        while index < range.upperBound {
            let character = command[index]
            if lexicalState.inComment {
                lexicalState.consume(character)
                index = command.index(after: index)
                continue
            }
            if lexicalState.startsComment(with: character) {
                lexicalState.beginComment()
                index = command.index(after: index)
                continue
            }
            guard lexicalState.quote == .unquoted, !lexicalState.escaped, character == "<" else {
                lexicalState.consume(character)
                index = command.index(after: index)
                continue
            }

            let suffix = command[index..<range.upperBound]
            if suffix.hasPrefix("<<<") {
                for _ in 0..<3 {
                    lexicalState.consume(command[index])
                    index = command.index(after: index)
                }
                continue
            }
            guard suffix.hasPrefix("<<") else {
                lexicalState.consume(character)
                index = command.index(after: index)
                continue
            }

            var cursor = command.index(index, offsetBy: 2)
            var stripsLeadingTabs = false
            if cursor < range.upperBound, command[cursor] == "-" {
                stripsLeadingTabs = true
                cursor = command.index(after: cursor)
            }
            while cursor < range.upperBound, command[cursor] == " " || command[cursor] == "\t" {
                cursor = command.index(after: cursor)
            }
            guard let parsed = parseDelimiter(
                in: command,
                from: cursor,
                through: range.upperBound
            ) else {
                lexicalState.consume(character)
                index = command.index(after: index)
                continue
            }
            pending.append(Descriptor(
                delimiter: parsed.delimiter,
                stripsLeadingTabs: stripsLeadingTabs,
                permitsEnvironmentExpansion: !parsed.wasQuoted
            ))
            while index < parsed.end {
                lexicalState.consume(command[index])
                index = command.index(after: index)
            }
        }
    }

    private func parseDelimiter(
        in command: String,
        from start: String.Index,
        through end: String.Index
    ) -> (delimiter: String, wasQuoted: Bool, end: String.Index)? {
        var delimiter = ""
        var quote = Quote.unquoted
        var wasQuoted = false
        var index = start
        while index < end {
            let character = command[index]
            if quote == .unquoted,
               character == " " || character == "\t" || ";|&<>()".contains(character) {
                break
            }
            switch (quote, character) {
            case (.unquoted, "'"), (.unquoted, "\""):
                wasQuoted = true
                quote = character == "'" ? .single : .double
            case (.single, "'"):
                quote = .unquoted
            case (.double, "\""):
                quote = .unquoted
            case (.unquoted, "\\"), (.double, "\\"):
                wasQuoted = true
                let escaped = command.index(after: index)
                guard escaped < end else {
                    index = escaped
                    continue
                }
                delimiter.append(command[escaped])
                index = escaped
            default:
                delimiter.append(character)
            }
            index = command.index(after: index)
        }
        guard !delimiter.isEmpty else { return nil }
        return (delimiter, wasQuoted, index)
    }
}

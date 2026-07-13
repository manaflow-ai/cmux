import Foundation

/// Locates here-document body and terminator lines so the task command
/// composer can treat them as data instead of shell syntax.
struct MobileTaskHereDocumentParser {
    struct Body {
        let range: Range<String.Index>
        let permitsEnvironmentExpansion: Bool
    }

    private struct Descriptor {
        let delimiter: String
        let stripsLeadingTabs: Bool
        let permitsEnvironmentExpansion: Bool
    }

    func bodies(in command: String) -> [Body] {
        var bodies: [Body] = []
        var pending: [Descriptor] = []
        var lexicalState = MobileTaskShellLexicalState()
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
                readingBodies = !pending.isEmpty && lexicalState.permitsHereDocumentOperator
            }

            if newline != nil { lexicalState.consume("\n") }
            lineStart = lineEnd
        }
        return bodies
    }

    private func scanDescriptors(
        in command: String,
        range: Range<String.Index>,
        lexicalState: inout MobileTaskShellLexicalState,
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
            guard lexicalState.permitsHereDocumentOperator, character == "<" else {
                index = lexicalState.advance(in: command, from: index, through: range.upperBound)
                continue
            }

            let suffix = command[index..<range.upperBound]
            if suffix.hasPrefix("<<<") {
                for _ in 0..<3 {
                    index = lexicalState.advance(in: command, from: index, through: range.upperBound)
                }
                continue
            }
            guard suffix.hasPrefix("<<") else {
                index = lexicalState.advance(in: command, from: index, through: range.upperBound)
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
                index = lexicalState.advance(in: command, from: index, through: range.upperBound)
                continue
            }
            pending.append(Descriptor(
                delimiter: parsed.delimiter,
                stripsLeadingTabs: stripsLeadingTabs,
                permitsEnvironmentExpansion: !parsed.wasQuoted
            ))
            while index < parsed.end {
                index = lexicalState.advance(in: command, from: index, through: parsed.end)
            }
        }
    }

    private func parseDelimiter(
        in command: String,
        from start: String.Index,
        through end: String.Index
    ) -> (delimiter: String, wasQuoted: Bool, end: String.Index)? {
        var delimiter = ""
        var quote = MobileTaskShellLexicalState.Quote.unquoted
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

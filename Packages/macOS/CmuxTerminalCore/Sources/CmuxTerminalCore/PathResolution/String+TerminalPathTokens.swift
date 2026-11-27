import Foundation

// Receiver-natural pure transforms behind terminal path resolution: smart
// trailing-punctuation trimming, visible-line capture, shell-token unquoting
// and unescaping, and the column-to-token heuristics. The constant tables are
// private implementation details of these transforms; everything stateful
// (file-system probing) lives on `TerminalPathResolver`.

extension String {
    private static let sentencePunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?"
    ]

    private static let trailingQuotes: Set<Character> = [
        "\"", "'", "”", "’", "»"
    ]

    private static let closingPairs: [Character: Character] = [
        ")": "(",
        "]": "[",
        "}": "{",
        ">": "<"
    ]

    /// Mirrors smart-link terminals by trimming only the trailing punctuation
    /// run that is clearly outside the path itself.
    ///
    /// Sentence punctuation and closing quotes always trim; a closing
    /// bracket trims only when no unmatched opening sibling remains earlier in
    /// the token, so balanced pairs inside a path survive. "Terminal" in the
    /// name is load-bearing: these are the terminal smart-link rules, not a
    /// general-purpose punctuation strip.
    ///
    /// - Returns: The token with extraneous trailing punctuation removed.
    public func trimmingTrailingTerminalPunctuation() -> String {
        let characters = Array(self)
        guard !characters.isEmpty else { return self }

        var end = characters.count
        while end > 0 {
            let trailing = characters[end - 1]
            if Self.sentencePunctuation.contains(trailing) ||
                Self.trailingQuotes.contains(trailing) {
                end -= 1
                continue
            }

            if let opener = Self.closingPairs[trailing],
               !characters[..<(end - 1)].hasUnmatchedOpeningDelimiter(
                   opener: opener,
                   closer: trailing
               ) {
                end -= 1
                continue
            }

            break
        }

        guard end < characters.count else { return self }
        return String(characters[..<end])
    }

    /// Returns the bottom `rows` lines of captured terminal text.
    ///
    /// - Parameter rows: The number of visible rows.
    /// - Returns: At most `rows` trailing lines, preserving empty lines.
    public func visibleLines(rows: Int) -> [String] {
        let lines = split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > rows {
            return Array(lines.suffix(rows))
        }
        return lines
    }

    /// The receiver with one layer of matching shell quotes removed, or `nil`
    /// when the receiver is not a fully quoted token.
    func unquotedShellToken() -> String? {
        guard count >= 2,
              let first, let last,
              first == last,
              first == "'" || first == "\"" else {
            return nil
        }
        return String(dropFirst().dropLast())
    }

    /// The receiver with shell backslash escapes folded into the escaped
    /// characters; a trailing lone backslash survives literally.
    func unescapingShellBackslashes() -> String {
        var output = String.UnicodeScalarView()
        output.reserveCapacity(unicodeScalars.count)
        var escaping = false

        for scalar in unicodeScalars {
            if escaping {
                output.append(scalar)
                escaping = false
                continue
            }

            if scalar == "\\" {
                escaping = true
                continue
            }

            output.append(scalar)
        }

        if escaping {
            output.append(UnicodeScalar(0x5C)!)
        }

        return String(output)
    }

    /// Candidate path spellings derived from the receiver: the raw text, its
    /// shell-unescaped and shell-unquoted variants, each with and without
    /// trailing terminal punctuation. Order is probe order; duplicates are
    /// dropped.
    func pathResolutionCandidates() -> [String] {
        var candidates: [String] = []

        func append(_ candidate: String?) {
            guard let candidate else { return }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            func appendUnique(_ value: String) {
                guard !value.isEmpty, !candidates.contains(value) else { return }
                candidates.append(value)
            }

            appendUnique(trimmed)
            let punctuationTrimmed = trimmed.trimmingTrailingTerminalPunctuation()
            if punctuationTrimmed != trimmed {
                appendUnique(punctuationTrimmed)
            }
        }

        append(self)

        let unescaped = unescapingShellBackslashes()
        if unescaped != self {
            append(unescaped)
        }

        if let unquoted = unquotedShellToken() {
            append(unquoted)
            let unescapedUnquoted = unquoted.unescapingShellBackslashes()
            if unescapedUnquoted != unquoted {
                append(unescapedUnquoted)
            }
        }

        return candidates
    }

    /// Path-token candidates around a column of a visible terminal line: the
    /// raw whitespace-delimited segment first, then the shell-escape-aware
    /// token.
    func pathTokenCandidates(containingColumn column: Int) -> [String] {
        var candidates: [String] = []

        func append(_ candidate: String?) {
            guard let candidate else { return }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
            candidates.append(trimmed)
        }

        append(rawPathSegment(containingColumn: column))
        append(shellEscapedToken(containingColumn: column))

        return candidates
    }

    private func rawPathSegment(containingColumn column: Int) -> String? {
        let characters = Array(self)
        guard !characters.isEmpty, column >= 0, column < characters.count else { return nil }
        guard !characters.isHardPathDelimiter(at: column) else { return nil }

        var start = column
        while start > 0, !characters.isHardPathDelimiter(at: start - 1) {
            start -= 1
        }

        var end = column
        while (end + 1) < characters.count, !characters.isHardPathDelimiter(at: end + 1) {
            end += 1
        }

        let candidate = String(characters[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private func shellEscapedToken(containingColumn column: Int) -> String? {
        let characters = Array(self)
        guard !characters.isEmpty, column >= 0, column < characters.count else { return nil }

        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
            let start = index

            while index < characters.count {
                let character = characters[index]
                guard character.isWhitespace else {
                    index += 1
                    continue
                }

                var backslashCount = 0
                var lookbehind = index - 1
                while lookbehind >= start, characters[lookbehind] == "\\" {
                    backslashCount += 1
                    lookbehind -= 1
                }

                if backslashCount % 2 == 1 {
                    index += 1
                    continue
                }

                break
            }

            if start < index, column >= start, column < index {
                return String(characters[start..<index])
            }
        }

        return nil
    }
}

extension ArraySlice<Character> {
    /// Whether an opening `opener` earlier in the slice is still unmatched by
    /// a `closer`, meaning a trailing `closer` belongs to the path.
    fileprivate func hasUnmatchedOpeningDelimiter(
        opener: Character,
        closer: Character
    ) -> Bool {
        var balance = 0
        for character in self {
            if character == opener {
                balance += 1
            } else if character == closer, balance > 0 {
                balance -= 1
            }
        }
        return balance > 0
    }
}

extension [Character] {
    /// Whether the character at `index` hard-delimits a path token: tabs and
    /// newlines always, spaces only when doubled (cell-grid padding).
    fileprivate func isHardPathDelimiter(at index: Int) -> Bool {
        let character = self[index]
        if character == "\t" || character == "\n" || character == "\r" {
            return true
        }

        guard character.isWhitespace else { return false }
        let previousIsWhitespace = index > 0 && self[index - 1].isWhitespace
        let nextIsWhitespace = (index + 1) < count && self[index + 1].isWhitespace
        return previousIsWhitespace || nextIsWhitespace
    }
}

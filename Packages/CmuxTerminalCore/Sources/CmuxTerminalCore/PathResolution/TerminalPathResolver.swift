public import Foundation

/// Resolves file-system paths out of raw terminal text.
///
/// This is the shared path heuristics layer behind cmd-click QuickLook,
/// "open file at cursor", and terminal link opening: shell-token unquoting and
/// unescaping, smart trailing-punctuation trimming, visible-line tokenization,
/// and cwd-relative resolution against an injectable existence check.
///
/// Static members are justified here: every operation is a pure function of
/// its inputs (the `fileExists` probe is a parameter, defaulting to the real
/// file system), and the plan folds the legacy file-scope helpers and constant
/// sets into this one utility type.
public struct TerminalPathResolver {
    private init() {}

    // MARK: - QuickLook resolution

    /// Resolves raw terminal text to an existing file path for QuickLook.
    ///
    /// Candidates are derived from the raw text (as-is, shell-unescaped,
    /// shell-unquoted, and trailing-punctuation-trimmed variants), expanded
    /// for `~`, resolved against `cwd` when relative, standardized, and probed
    /// in order. The first existing path wins.
    ///
    /// - Parameters:
    ///   - rawText: The raw text under the cursor or selection.
    ///   - cwd: The surface's working directory used for relative candidates.
    ///   - fileExists: The existence probe; defaults to the real file system.
    /// - Returns: The first existing standardized path, or `nil`.
    public static func resolveQuicklookPath(
        _ rawText: String,
        cwd: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var seenPaths: Set<String> = []
        for token in quicklookPathCandidates(from: trimmed) {
            let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedToken.isEmpty else { continue }

            let expandedToken = (normalizedToken as NSString).expandingTildeInPath
            let candidatePath: String
            if expandedToken.hasPrefix("/") {
                candidatePath = expandedToken
            } else {
                guard let cwd, !cwd.isEmpty else { continue }
                candidatePath = (cwd as NSString).appendingPathComponent(expandedToken)
            }

            let standardizedPath = (candidatePath as NSString).standardizingPath
            guard seenPaths.insert(standardizedPath).inserted else { continue }
            if fileExists(standardizedPath) {
                return standardizedPath
            }
        }

        return nil
    }

    private static func quicklookPathCandidates(from rawText: String) -> [String] {
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
            let punctuationTrimmed = trimTrailingPunctuation(trimmed)
            if punctuationTrimmed != trimmed {
                appendUnique(punctuationTrimmed)
            }
        }

        append(rawText)

        let unescaped = unescapeShellToken(rawText)
        if unescaped != rawText {
            append(unescaped)
        }

        if let unquoted = unquoteShellToken(rawText) {
            append(unquoted)
            let unescapedUnquoted = unescapeShellToken(unquoted)
            if unescapedUnquoted != unquoted {
                append(unescapedUnquoted)
            }
        }

        return candidates
    }

    // MARK: - Trailing punctuation

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
    /// the token, so balanced pairs inside a path survive.
    ///
    /// - Parameter token: The candidate path token.
    /// - Returns: The token with extraneous trailing punctuation removed.
    public static func trimTrailingPunctuation(_ token: String) -> String {
        let characters = Array(token)
        guard !characters.isEmpty else { return token }

        var end = characters.count
        while end > 0 {
            let trailing = characters[end - 1]
            if sentencePunctuation.contains(trailing) ||
                trailingQuotes.contains(trailing) {
                end -= 1
                continue
            }

            if let opener = closingPairs[trailing],
               !hasUnmatchedOpeningDelimiter(
                   in: characters[..<(end - 1)],
                   opener: opener,
                   closer: trailing
               ) {
                end -= 1
                continue
            }

            break
        }

        guard end < characters.count else { return token }
        return String(characters[..<end])
    }

    private static func hasUnmatchedOpeningDelimiter(
        in characters: ArraySlice<Character>,
        opener: Character,
        closer: Character
    ) -> Bool {
        var balance = 0
        for character in characters {
            if character == opener {
                balance += 1
            } else if character == closer, balance > 0 {
                balance -= 1
            }
        }
        return balance > 0
    }

    // MARK: - Shell tokens

    private static func unquoteShellToken(_ token: String) -> String? {
        guard token.count >= 2,
              let first = token.first,
              let last = token.last,
              first == last,
              first == "'" || first == "\"" else {
            return nil
        }
        return String(token.dropFirst().dropLast())
    }

    private static func unescapeShellToken(_ token: String) -> String {
        var output = String.UnicodeScalarView()
        output.reserveCapacity(token.unicodeScalars.count)
        var escaping = false

        for scalar in token.unicodeScalars {
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

    // MARK: - Visible-line resolution

    /// Returns the bottom `rows` lines of captured terminal text.
    ///
    /// - Parameters:
    ///   - text: The captured terminal text.
    ///   - rows: The number of visible rows.
    /// - Returns: At most `rows` trailing lines, preserving empty lines.
    public static func visibleLines(from text: String, rows: Int) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > rows {
            return Array(lines.suffix(rows))
        }
        return lines
    }

    private static func shellEscapedTokenContainingColumn(
        in line: String,
        column: Int
    ) -> String? {
        let characters = Array(line)
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

    private static func isHardPathDelimiter(
        in characters: [Character],
        at index: Int
    ) -> Bool {
        let character = characters[index]
        if character == "\t" || character == "\n" || character == "\r" {
            return true
        }

        guard character.isWhitespace else { return false }
        let previousIsWhitespace = index > 0 && characters[index - 1].isWhitespace
        let nextIsWhitespace = (index + 1) < characters.count && characters[index + 1].isWhitespace
        return previousIsWhitespace || nextIsWhitespace
    }

    private static func rawPathSegmentContainingColumn(
        in line: String,
        column: Int
    ) -> String? {
        let characters = Array(line)
        guard !characters.isEmpty, column >= 0, column < characters.count else { return nil }
        guard !isHardPathDelimiter(in: characters, at: column) else { return nil }

        var start = column
        while start > 0, !isHardPathDelimiter(in: characters, at: start - 1) {
            start -= 1
        }

        var end = column
        while (end + 1) < characters.count, !isHardPathDelimiter(in: characters, at: end + 1) {
            end += 1
        }

        let candidate = String(characters[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private static func pathCandidatesContainingColumn(
        in line: String,
        column: Int
    ) -> [String] {
        var candidates: [String] = []

        func append(_ candidate: String?) {
            guard let candidate else { return }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
            candidates.append(trimmed)
        }

        append(rawPathSegmentContainingColumn(in: line, column: column))
        append(shellEscapedTokenContainingColumn(in: line, column: column))

        return candidates
    }

    /// Resolves the path token under a column of a visible terminal line.
    ///
    /// Tries the raw whitespace-delimited segment around the column first,
    /// then the shell-escape-aware token, and resolves each through
    /// ``resolveQuicklookPath(_:cwd:fileExists:)``.
    ///
    /// - Parameters:
    ///   - line: The visible line text.
    ///   - column: The zero-based column under the cursor.
    ///   - cwd: The surface's working directory.
    ///   - fileExists: The existence probe; defaults to the real file system.
    /// - Returns: The raw token plus its resolved path, or `nil`.
    public static func resolveVisibleLinePath(
        _ line: String,
        column: Int,
        cwd: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (rawToken: String, path: String)? {
        for rawToken in pathCandidatesContainingColumn(in: line, column: column) {
            if let resolvedPath = resolveQuicklookPath(rawToken, cwd: cwd, fileExists: fileExists) {
                return (rawToken, resolvedPath)
            }
        }
        return nil
    }

    /// Resolves an open-URL request payload to an existing file path.
    ///
    /// Text that parses as a URL with a scheme is never treated as a file
    /// path; everything else goes through
    /// ``resolveQuicklookPath(_:cwd:fileExists:)``.
    ///
    /// - Parameters:
    ///   - rawText: The raw open-URL text from the runtime.
    ///   - cwd: The surface's working directory.
    ///   - fileExists: The existence probe; defaults to the real file system.
    /// - Returns: The first existing standardized path, or `nil`.
    public static func resolveOpenURLFilePath(
        _ rawText: String,
        cwd: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard URL(string: trimmed)?.scheme == nil else { return nil }
        return resolveQuicklookPath(trimmed, cwd: cwd, fileExists: fileExists)
    }
}

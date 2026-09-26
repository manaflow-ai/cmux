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

extension String {
    /// Whether the receiver starts with an explicit root or relative marker
    /// (`/`, `./`, `../`, `~/`) rather than being a bare relative token.
    fileprivate var hasExplicitTerminalRelativeMarker: Bool {
        hasPrefix("/") || hasPrefix("./") || hasPrefix("../") || hasPrefix("~/")
    }

    /// The token touching `column` on a hard-wrapped row, plus which
    /// adjacent row(s) could complete it.
    ///
    /// A token with an explicit root/relative marker (`/`, `./`, `../`,
    /// `~/`) only ever tries `.next` (continuation below), and only when it
    /// touches the row's trailing boundary — it never tries both
    /// directions, since a real wrap after `/` is indistinguishable from an
    /// independent absolute path on the next row (see
    /// `resolveWrappedCandidate`'s doc comment).
    ///
    /// A bare-relative token (no explicit marker) tries whichever
    /// boundaries it touches: leading only → `.previous`; trailing only →
    /// `.next`; both → `.previous` **and** `.next` (ambiguous; the caller
    /// resolves both and keeps the result only if exactly one succeeds);
    /// neither → `nil`. The trailing boundary is nothing but whitespace
    /// after the token (the logical line end, not necessarily the physical
    /// grid width); the leading boundary is nothing but `maxIndentation` or
    /// fewer ASCII spaces before it.
    ///
    /// Returns `nil` for non-ASCII rows (fail-closed: `column` is a
    /// terminal-cell index, which only lines up with `String` character
    /// indices when every character occupies exactly one cell), or when the
    /// clicked cell is itself a delimiter.
    func wrapContinuationToken(
        atColumn column: Int,
        maxIndentation: Int
    ) -> (token: String, directions: [TerminalWrapDirection], startColumn: Int, endColumn: Int)? {
        guard unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let characters = Array(self)
        guard !characters.isEmpty, column >= 0, column < characters.count else { return nil }
        guard !characters.isWrapTokenBoundary(at: column) else { return nil }

        var start = column
        while start > 0, !characters.isWrapTokenBoundary(at: start - 1) {
            start -= 1
        }
        var end = column
        while (end + 1) < characters.count, !characters.isWrapTokenBoundary(at: end + 1) {
            end += 1
        }

        let token = String(characters[start...end])
        guard !token.isEmpty else { return nil }
        // ASCII-only (guarded above), so character index == terminal column.
        let startColumn = start
        let endColumn = end + 1

        let touchesTrailingBoundary = characters[(end + 1)...].allSatisfy(\.isWhitespace)
        let leadingRun = characters[..<start]
        let touchesLeadingBoundary = leadingRun.count <= maxIndentation &&
            leadingRun.allSatisfy { $0 == " " }

        if token.hasExplicitTerminalRelativeMarker {
            guard touchesTrailingBoundary else { return nil }
            return (token, [.next], startColumn, endColumn)
        }

        switch (touchesLeadingBoundary, touchesTrailingBoundary) {
        case (true, true):
            return (token, [.previous, .next], startColumn, endColumn)
        case (true, false):
            return (token, [.previous], startColumn, endColumn)
        case (false, true):
            return (token, [.next], startColumn, endColumn)
        case (false, false):
            return nil
        }
    }

    /// The first token on a continuation row, provided it starts within
    /// `maxIndentation` ASCII spaces of the row's start.
    ///
    /// - Returns: The leading token, or `nil` for non-ASCII rows or rows
    ///   with no token within the indentation bound.
    func leadingContinuationFragment(maxIndentation: Int) -> String? {
        leadingContinuationFragmentWithRange(maxIndentation: maxIndentation)?.fragment
    }

    /// Same as ``leadingContinuationFragment(maxIndentation:)``, but also
    /// returns the fragment's column range (half-open) for (B) ExternalHover
    /// underlining — see ``TerminalWrappedPathCellSpan``.
    func leadingContinuationFragmentWithRange(
        maxIndentation: Int
    ) -> (fragment: String, startColumn: Int, endColumn: Int)? {
        guard unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let characters = Array(self)

        var index = 0
        while index < characters.count, characters[index] == " " {
            index += 1
        }
        guard index <= maxIndentation,
              index < characters.count,
              !characters.isWrapTokenBoundary(at: index) else {
            return nil
        }

        var end = index
        while (end + 1) < characters.count, !characters.isWrapTokenBoundary(at: end + 1) {
            end += 1
        }
        let fragment = String(characters[index...end])
        guard !fragment.isEmpty else { return nil }
        return (fragment, index, end + 1)
    }

    /// The last token on a continuation row, ignoring trailing grid
    /// padding (physical rows are read unpadded-but-untrimmed, so the tail
    /// of a shorter line is trailing ASCII spaces, not the wrapped text).
    ///
    /// - Returns: The trailing token, or `nil` for non-ASCII rows or rows
    ///   with no trailing token.
    func trailingContinuationFragment() -> String? {
        trailingContinuationFragmentWithRange()?.fragment
    }

    /// Same as ``trailingContinuationFragment()``, but also returns the
    /// fragment's column range (half-open) for (B) ExternalHover
    /// underlining — see ``TerminalWrappedPathCellSpan``.
    func trailingContinuationFragmentWithRange() -> (fragment: String, startColumn: Int, endColumn: Int)? {
        guard unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return trailingContinuationFragmentScan()
    }

    /// design-next-round-bundle-8810.md §1 — the same trailing token
    /// ``trailingContinuationFragmentWithRange()`` extracts, but with
    /// neither its ASCII guard nor a column range. That guard exists
    /// ONLY to keep `startColumn`/`endColumn` valid terminal-cell indices
    /// (a non-ASCII character can occupy a different number of cells
    /// than `String` character indices assume) — the token's TEXT itself
    /// never depends on any column projection: trimming trailing
    /// grid-padding spaces and walking back to the nearest whitespace
    /// boundary is purely textual, Character-indexed work.
    ///
    /// Exists so `TerminalPathResolver`'s `.previous`-direction
    /// resolution can still extract a real fragment from a non-ASCII
    /// previous row when the caller has no use for a column range — the
    /// click-only fallback design-next-round-bundle-8810.md §1
    /// specifies. (B) ExternalHover's underline is the one thing that
    /// DOES need columns, so it never resolves through this path (see
    /// ``TerminalWrappedCellSpans/unavailableNonASCIIRow``).
    ///
    /// - Returns: The trailing fragment, or `nil` for a row that's empty
    ///   or entirely whitespace.
    func trailingContinuationFragmentText() -> String? {
        trailingContinuationFragmentScan()?.fragment
    }

    private func trailingContinuationFragmentScan()
        -> (fragment: String, startColumn: Int, endColumn: Int)?
    {
        let characters = Array(self)
        guard !characters.isEmpty else { return nil }

        var end = characters.count - 1
        while end >= 0, characters[end] == " " {
            end -= 1
        }
        guard end >= 0, !characters.isWrapTokenBoundary(at: end) else { return nil }

        var start = end
        while start > 0, !characters.isWrapTokenBoundary(at: start - 1) {
            start -= 1
        }
        let fragment = String(characters[start...end])
        guard !fragment.isEmpty else { return nil }
        return (fragment, start, end + 1)
    }

    /// final-spec-scope-expansion-8810.md §1 — the 0-indexed column of the
    /// row's last non-whitespace character, for the contiguous-span
    /// evaluator's fullness guard ("does this row reach the strict
    /// physical right edge"). `nil` for non-ASCII rows (fail-closed, same
    /// convention as the other wrap-continuation extractors) or a row
    /// that's empty/entirely whitespace.
    public var lastNonWhitespaceColumn: Int? {
        guard unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let characters = Array(self)
        var index = characters.count - 1
        while index >= 0, characters[index].isWhitespace {
            index -= 1
        }
        return index >= 0 ? index : nil
    }

    /// final-spec §4.1 — a *middle* row's full contribution to a
    /// multi-row wrapped-path span: the whole row, minus leading/trailing
    /// ASCII-space grid padding. Unlike
    /// ``trailingContinuationFragmentWithRange()``/
    /// ``leadingContinuationFragmentWithRange(maxIndentation:)``, this
    /// never extracts just the last/first *token* bounded by internal
    /// whitespace — a middle row is fully enclosed within the span (its
    /// neighbors on both sides are also part of the same candidate), so
    /// its entire visible content participates, not a sub-token of it.
    ///
    /// - Returns: The trimmed content and its column range (half-open),
    ///   or `nil` for a non-ASCII row or one that's entirely padding.
    func gridPaddingTrimmedWithRange() -> (fragment: String, startColumn: Int, endColumn: Int)? {
        guard unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let characters = Array(self)
        var start = 0
        while start < characters.count, characters[start] == " " {
            start += 1
        }
        var end = characters.count - 1
        while end >= start, characters[end] == " " {
            end -= 1
        }
        guard start <= end else { return nil }
        return (String(characters[start...end]), start, end + 1)
    }

    /// The exact-match key used to correlate a wrapped-path candidate
    /// against a native Ghostty `open_url` callback for the same click.
    func normalizedTerminalWrapMatchKey() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a joined wrapped-path candidate is shaped like a real path
    /// rather than an incidental concatenation of two unrelated tokens.
    ///
    /// Absolute paths always qualify. A relative candidate qualifies only
    /// with an explicit relative marker (`./`, `../`, `~/`), or by both
    /// containing `/` and having a dotted leaf — mirroring the shape
    /// Ghostty's own `bare_relative_path_branch` accepts
    /// (`ghostty/src/config/url.zig`), so this never treats something
    /// Ghostty's own matcher wouldn't as path-shaped.
    var isWrappedPathCandidateShaped: Bool {
        if hasExplicitTerminalRelativeMarker { return true }
        guard contains("/") else { return false }
        return contains(".")
    }

    /// Whether the receiver alone is shaped like a path *prefix*: an
    /// explicit relative marker, or (for a bare relative piece) at least
    /// one `/`. Unlike ``isWrappedPathCandidateShaped``, this doesn't
    /// require a dotted leaf — it's applied to whichever fragment leads a
    /// joined bidirectional candidate (the clicked token for `.next`, the
    /// adjacent row's fragment for `.previous`) to require that piece look
    /// like a real path prefix on its own, not just the concatenation as a
    /// whole. Without this, two unrelated bare words that happen to
    /// concatenate into an existing relative path (e.g. adjacent row `foo`,
    /// clicked token `bar`, with `cwd/foobar` existing) would false-positive.
    var isWrappedPathPrefixShaped: Bool {
        hasExplicitTerminalRelativeMarker || contains("/")
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

    /// Whether the character at `index` delimits a hard-wrap continuation
    /// token or fragment: any whitespace at all, not just doubled runs.
    ///
    /// Unlike ``isHardPathDelimiter(at:)`` (used for row-local resolution,
    /// where a single space must stay tolerable so multi-word filenames
    /// like "My File.txt" can be clicked directly), the wrap-continuation
    /// extractors (`wrapContinuationToken`, `leadingContinuationFragment`,
    /// `trailingContinuationFragment`) mirror Ghostty's own
    /// `bare_relative_path_branch`, whose `path_chars` class excludes space
    /// entirely (`ghostty/src/config/url.zig`). Tolerating single spaces
    /// here let arbitrary same-row prose ahead of a real path (list markers,
    /// labels — e.g. `- html: /Users/.../file.html`) get swallowed into the
    /// fragment, producing a garbage-prefixed candidate that can never
    /// resolve even though the real path underneath exists (issue #8810,
    /// dogfood repro where `noCandidate` fired for both directions despite
    /// correct rows and an existing joined path).
    fileprivate func isWrapTokenBoundary(at index: Int) -> Bool {
        self[index].isWhitespace
    }
}

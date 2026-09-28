import Foundation

/// Locates outline prompts in captured terminal history.
///
/// Agents echo each submitted prompt into the terminal behind a prompt glyph
/// (`❯`, `›`, `>`). The resolver finds the physical row where each prompt
/// starts, joining soft-wrapped continuation rows, and never guesses: a
/// prompt that no longer appears (cleared screen, alternate-screen TUI,
/// trimmed scrollback, pasted-text placeholder) has no row.
public struct ChatOutlineAnchorResolver: Sendable {
    static let promptPrefixes = ["❯ ", "› ", "> ", "$ ", "% ", "# ", ">>> "]
    /// Continuation rows joined while matching one wrapped prompt.
    private static let maxContinuationRows = 64

    /// Creates an anchor resolver.
    public init() {}

    /// Resolves the start row of every entry at once.
    ///
    /// Matching runs newest to oldest and keeps rows strictly increasing with
    /// entry order, so a prompt repeated in the conversation or reprinted by
    /// the agent's own redraw anchors to its latest consistent copy, and an
    /// older entry can never claim a row below a newer one.
    ///
    /// - Parameters:
    ///   - entries: Outline entries in transcript order.
    ///   - history: Physical terminal rows, top to bottom, one per line.
    ///   - rowOffset: Absolute row of the first line in `history`.
    /// - Returns: Absolute start row per entry id; entries with no row are
    ///   absent.
    public func rows(
        for entries: [ChatOutlineEntry],
        in history: String,
        rowOffset: Int = 0
    ) -> [String: Int] {
        guard !entries.isEmpty else { return [:] }
        let lines = history.split(separator: "\n", omittingEmptySubsequences: false)
        var rows = NormalizedRows(lines: lines)
        let promptRows = lines.indices.filter { Self.mayStartPrompt(lines[$0]) }
        guard !promptRows.isEmpty else { return [:] }

        var result: [String: Int] = [:]
        // Prompt rows at or after this index are claimed by newer entries.
        var upperBound = promptRows.count
        for entry in entries.reversed() {
            let target = Self.normalized(Substring(entry.title))
            guard !target.isEmpty else { continue }
            var candidate = upperBound - 1
            while candidate >= 0 {
                let row = promptRows[candidate]
                if matches(
                    target: target,
                    allowsClippedMatch: entry.isTitleClipped,
                    startingAt: row,
                    in: &rows
                ) {
                    result[entry.id] = row + rowOffset
                    upperBound = candidate
                    break
                }
                candidate -= 1
            }
        }
        return result
    }

    /// Returns the row of one entry, resolved together with the rest of the
    /// outline so repeated prompts are disambiguated.
    ///
    /// - Parameters:
    ///   - entry: The prompt to locate.
    ///   - entries: The complete outline, in transcript order.
    ///   - history: Physical terminal rows in top-to-bottom order.
    /// - Returns: The matching row, or `nil` when history no longer contains
    ///   the prompt.
    public func row(
        for entry: ChatOutlineEntry,
        among entries: [ChatOutlineEntry],
        in history: String
    ) -> Int? {
        rows(for: entries, in: history)[entry.id]
    }

    // MARK: - Matching

    private func matches(
        target: String,
        allowsClippedMatch: Bool,
        startingAt row: Int,
        in rows: inout NormalizedRows
    ) -> Bool {
        let first = rows[row]
        guard let prefix = Self.promptPrefixes.first(where: { first.hasPrefix($0) }) else {
            return false
        }
        let head = String(first.dropFirst(prefix.count))
        if Self.contentMatches(head, target: target, allowsClippedMatch: allowsClippedMatch) {
            return true
        }
        guard target.hasPrefix(head) else { return false }
        // A soft wrap may fall between words (the row ends at a space the
        // capture dropped) or inside a word, so carry both joins.
        var candidates = [head]
        var next = row + 1
        while next < rows.count, next - row <= Self.maxContinuationRows {
            let continuation = rows[next]
            guard !continuation.isEmpty, !Self.isPromptRow(continuation) else { return false }
            candidates = candidates
                .flatMap { [$0 + " " + continuation, $0 + continuation] }
                .filter { target.hasPrefix($0) || (allowsClippedMatch && $0.hasPrefix(target)) }
            if candidates.contains(where: {
                Self.contentMatches($0, target: target, allowsClippedMatch: allowsClippedMatch)
            }) {
                return true
            }
            if candidates.isEmpty { return false }
            next += 1
        }
        return false
    }

    private static func contentMatches(
        _ candidate: String,
        target: String,
        allowsClippedMatch: Bool
    ) -> Bool {
        candidate == target || (allowsClippedMatch && candidate.hasPrefix(target))
    }

    private static func isPromptRow(_ row: String) -> Bool {
        promptPrefixes.contains { row.hasPrefix($0) }
    }

    /// Cheap pre-filter on the raw row: the first visible scalar can start a
    /// prompt glyph (escape sequences are allowed ahead of it).
    private static func mayStartPrompt(_ line: Substring) -> Bool {
        for scalar in line.unicodeScalars {
            switch scalar {
            case " ", "\t":
                continue
            case "❯", "›", ">", "$", "%", "#", "\u{1B}":
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Lazily normalized row cache.
    private struct NormalizedRows {
        let lines: [Substring]
        private var cache: [Int: String] = [:]

        init(lines: [Substring]) {
            self.lines = lines
        }

        var count: Int { lines.count }

        subscript(index: Int) -> String {
            mutating get {
                if let cached = cache[index] { return cached }
                let value = ChatOutlineAnchorResolver.normalized(lines[index])
                cache[index] = value
                return value
            }
        }
    }

    /// Strips ANSI escape sequences, collapses whitespace runs to one space,
    /// trims, and lowercases.
    static func normalized(_ text: Substring) -> String {
        enum EscapeState {
            case none
            case afterEscape
            case csi
            case osc
            case oscEscape
        }

        var result = ""
        var escapeState = EscapeState.none
        var needsSpace = false

        for scalar in text.unicodeScalars {
            switch escapeState {
            case .afterEscape:
                if scalar == "[" {
                    escapeState = .csi
                } else if scalar == "]" {
                    escapeState = .osc
                } else {
                    escapeState = .none
                }
                continue
            case .csi:
                if (0x40...0x7E).contains(scalar.value) {
                    escapeState = .none
                } else if scalar.value == 0x1B {
                    escapeState = .afterEscape
                }
                continue
            case .osc:
                if scalar.value == 0x07 {
                    escapeState = .none
                } else if scalar.value == 0x1B {
                    escapeState = .oscEscape
                }
                continue
            case .oscEscape:
                escapeState = scalar == "\\" ? .none : .osc
                continue
            case .none:
                if scalar.value == 0x1B {
                    escapeState = .afterEscape
                    continue
                }
            }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.value == 0xA0 {
                needsSpace = !result.isEmpty
                continue
            }
            if needsSpace {
                result.append(" ")
                needsSpace = false
            }
            result.unicodeScalars.append(scalar)
        }
        return result.lowercased()
    }
}

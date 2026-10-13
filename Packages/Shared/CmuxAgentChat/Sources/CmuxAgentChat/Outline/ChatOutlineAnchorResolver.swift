import Foundation

/// Locates outline prompts in captured terminal history.
///
/// Agents echo each submitted prompt into the terminal behind a prompt glyph
/// (`❯`, `›`, `>`). The resolver finds the physical row where each prompt
/// starts, joining soft-wrapped continuation rows, and never guesses: a
/// prompt that no longer appears (cleared screen, alternate-screen TUI,
/// trimmed scrollback, pasted-text placeholder) has no row.
public struct ChatOutlineAnchorResolver: Sendable {
    static let promptPrefixes = ["❯ ", "› ", "> "]
    /// Continuation rows joined while matching one wrapped prompt.
    private static let maxContinuationRows = 64

    /// Creates an anchor resolver.
    public init() {}

    /// Resolves the start row of every entry at once.
    ///
    /// Rows increase strictly with entry order. Among such assignments the
    /// resolver keeps the one that anchors the most entries, preferring later
    /// rows and newer entries on ties, so a prompt repeated in the
    /// conversation or reprinted by the agent's own redraw anchors to its
    /// latest consistent copy, and a newest prompt that is not echoed yet
    /// does not borrow an older copy's row unless every copy has the same
    /// text (no alignment can tell those apart).
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
        let index = PromptRowIndex(lines: lines, rows: &rows)
        guard !index.isEmpty else { return [:] }

        // Candidate rows per entry, ascending.
        var candidates: [[Int]] = []
        candidates.reserveCapacity(entries.count)
        for entry in entries {
            let target = Self.normalized(Substring(entry.title))
            guard !target.isEmpty else {
                candidates.append([])
                continue
            }
            let matching = index.candidateRows(for: target).filter {
                matches(target: target, allowsClippedMatch: entry.isTitleClipped, startingAt: $0, in: &rows)
            }
            candidates.append(matching)
        }
        return Self.align(entries: entries, candidates: candidates, rowOffset: rowOffset)
    }

    /// Longest strictly increasing (entry, row) chain over sparse matches.
    ///
    /// Walks entries newest first; within an entry, rows ascend so two rows
    /// of one entry never chain. Patience sorting on descending rows keeps,
    /// for each chain length, the chain whose oldest entry sits on the latest
    /// row; equal rows keep the newer entry.
    static func align(entries: [ChatOutlineEntry], candidates: [[Int]], rowOffset: Int) -> [String: Int] {
        struct Item {
            let entry: Int
            let row: Int
            let previous: Int?
        }
        var items: [Item] = []
        // tails[k]: item ending the best chain of length k + 1 (its row is
        // the largest seen for that length).
        var tails: [Int] = []
        for entryIndex in entries.indices.reversed() {
            var pending: [(position: Int, item: Item)] = []
            for row in candidates[entryIndex] {
                // First chain whose tail row is <= row: this row cannot extend it.
                var low = 0
                var high = tails.count
                while low < high {
                    let mid = (low + high) / 2
                    if items[tails[mid]].row <= row {
                        high = mid
                    } else {
                        low = mid + 1
                    }
                }
                let previous = low > 0 ? tails[low - 1] : nil
                pending.append((low, Item(entry: entryIndex, row: row, previous: previous)))
            }
            // Apply after scanning the entry, so its rows never chain together.
            for (position, item) in pending {
                items.append(item)
                let itemIndex = items.count - 1
                if position == tails.count {
                    tails.append(itemIndex)
                } else if items[tails[position]].row < item.row {
                    tails[position] = itemIndex
                }
            }
        }
        var result: [String: Int] = [:]
        var cursor = tails.last
        while let current = cursor {
            let item = items[current]
            result[entries[item.entry].id] = item.row + rowOffset
            cursor = item.previous
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
            case "❯", "›", ">", "\u{1B}":
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Prompt rows bucketed by the first characters of their content, so an
    /// entry only checks rows that can start with its title.
    private struct PromptRowIndex {
        static let keyLength = 16
        private var buckets: [String: [Int]] = [:]
        /// Rows whose first-row content is shorter than the key (a prompt
        /// wrapped after a few characters, or a very short prompt).
        private var shortRows: [Int] = []

        init(lines: [Substring], rows: inout NormalizedRows) {
            for index in lines.indices where ChatOutlineAnchorResolver.mayStartPrompt(lines[index]) {
                let row = rows[index]
                guard let prefix = ChatOutlineAnchorResolver.promptPrefixes.first(where: { row.hasPrefix($0) }) else {
                    continue
                }
                let head = row.dropFirst(prefix.count)
                if head.count < Self.keyLength {
                    shortRows.append(index)
                } else {
                    buckets[String(head.prefix(Self.keyLength)), default: []].append(index)
                }
            }
        }

        var isEmpty: Bool { buckets.isEmpty && shortRows.isEmpty }

        func candidateRows(for target: String) -> [Int] {
            guard target.count >= Self.keyLength else { return shortRows }
            let keyed = buckets[String(target.prefix(Self.keyLength))] ?? []
            guard !shortRows.isEmpty else { return keyed }
            return (keyed + shortRows).sorted()
        }
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
    private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0xA0:
            return true
        case 0..<0x80:
            return false
        default:
            return scalar.properties.isWhitespace
        }
    }

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

            if Self.isWhitespace(scalar) {
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

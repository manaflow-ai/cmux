import Foundation

/// What the file screen shows of one file, as a flat list of rows: hunk headers, collapsed
/// context ("Expand N lines"), gaps between parsed hunks, and code lines (one row per line,
/// or one row per old/new pair in Split). Pure and `Sendable`, so the screen builds it off
/// the main thread once per (file, options) and the list only reads it.
public struct DiffRows: Sendable {
    public struct Options: Hashable, Sendable {
        public var hideWhitespace: Bool
        public var split: Bool
        /// Context ranges the person expanded, in the indices of the (filtered) lines.
        public var expanded: [ClosedRange<Int>]

        public init(hideWhitespace: Bool = false, split: Bool = false, expanded: [ClosedRange<Int>] = []) {
            self.hideWhitespace = hideWhitespace
            self.split = split
            self.expanded = expanded
        }
    }

    public enum Row: Hashable, Sendable {
        /// A unified code line: an index into `lines`.
        case line(Int)
        /// A split pair: old line on the left, new line on the right (a context line is both).
        case split(left: Int?, right: Int?)
        case header(id: Int, text: String)
        case collapsed(ClosedRange<Int>)
        case gap(Int)

        /// Whether the row draws line `index` (a split pair draws two).
        public func shows(line index: Int) -> Bool {
            switch self {
            case .line(let line): line == index
            case .split(let left, let right): left == index || right == index
            default: false
            }
        }

        /// Stable across expansions (a line keeps its id), unique in one file's rows.
        public var id: String {
            switch self {
            case .line(let index): "l\(index)"
            case .split(let left, let right): "s\(left ?? -1)_\(right ?? -1)"
            case .header(let id, _): "h\(id)"
            case .collapsed(let range): "c\(range.lowerBound)"
            case .gap(let index): "g\(index)"
            }
        }
    }

    /// The file's lines as shown (Hide Whitespace drops blank-only changes).
    public let lines: [DiffLine]
    /// Each line with tabs expanded and highlights remapped (`DiffLayout.display`).
    public let displays: [DiffLayout.DisplayLine]
    public let rows: [Row]
    /// Columns of the longest displayed line (the unwrapped code width).
    public let longestColumns: Int

    public init(file: DiffFile, options: Options) {
        let lines = DiffNavigation.visibleLines(file.lines, hideWhitespace: options.hideWhitespace)
        self.lines = lines
        let displays = lines.map(DiffLayout.display)
        self.displays = displays
        var longest = 0
        for display in displays { longest = max(longest, display.text.utf16.count) }
        longestColumns = longest
        let segments = Self.segments(lines: lines, hasFullContext: file.hasFullContext, expanded: options.expanded)
        var rows: [Row] = []
        rows.reserveCapacity(lines.count + segments.count)
        for segment in segments {
            switch segment {
            case .header(let id, let text): rows.append(.header(id: id, text: text))
            case .collapsed(let range): rows.append(.collapsed(range))
            case .gap(let index): rows.append(.gap(index))
            case .lines(let range):
                if options.split {
                    rows += Self.splitRows(lines: lines, range: range)
                } else {
                    for index in range { rows.append(.line(index)) }
                }
            }
        }
        self.rows = rows
    }

    /// The first "Expand N lines" row (the demo's Expand command).
    public var firstCollapsed: ClosedRange<Int>? {
        for case .collapsed(let range) in rows { return range }
        return nil
    }

    // MARK: Segments

    enum Segment: Equatable {
        case header(id: Int, text: String)
        case lines(ClosedRange<Int>)
        case collapsed(ClosedRange<Int>)
        case gap(Int)
    }

    static func segments(lines: [DiffLine], hasFullContext: Bool, expanded: [ClosedRange<Int>]) -> [Segment] {
        guard !lines.isEmpty else { return [] }
        guard hasFullContext else {
            // Parsed diff or agent snippets: hunk lines with gap markers.
            var result: [Segment] = []
            var start = 0
            for (offset, line) in lines.enumerated() where line.isGap {
                if offset > start { result.append(.lines(start...offset - 1)) }
                result.append(.gap(offset))
                start = offset + 1
            }
            if start < lines.count { result.append(.lines(start...lines.count - 1)) }
            return result
        }
        var visible = changeRanges(lines, context: 3)
        if visible.isEmpty { visible = [0...lines.count - 1] }
        // Expanded ranges index the lines as they were (Hide Whitespace changes the count).
        let last = lines.count - 1
        visible += expanded.compactMap { range in
            range.lowerBound <= last ? range.lowerBound...min(range.upperBound, last) : nil
        }
        visible.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for range in visible {
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        // The changes themselves (no context) start the headers; each header names the nearest
        // declaration above its first change, as git does. One pass for both.
        let changeStarts = changeRanges(lines, context: 0).map(\.lowerBound)
        let declarations = nearestDeclarations(lines)
        var result: [Segment] = []
        var cursor = 0
        var nextChange = 0
        for range in merged {
            if range.lowerBound > cursor {
                result.append(.collapsed(cursor...range.lowerBound - 1))
            }
            while nextChange < changeStarts.count, changeStarts[nextChange] < range.lowerBound { nextChange += 1 }
            if nextChange < changeStarts.count, changeStarts[nextChange] <= range.upperBound {
                let declaration = declarations[changeStarts[nextChange]]
                result.append(.header(id: range.lowerBound, text: headerText(lines[range], declaration: declaration)))
            }
            result.append(.lines(range))
            cursor = range.upperBound + 1
        }
        if cursor < lines.count {
            result.append(.collapsed(cursor...lines.count - 1))
        }
        return result
    }

    /// Ranges around each changed line (`DiffFile.hunks(context:)` without building headers).
    static func changeRanges(_ lines: [DiffLine], context: Int) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for index in lines.indices where lines[index].kind != .context || lines[index].isGap {
            let low = max(0, index - context)
            let high = min(lines.count - 1, index + context)
            if let last = ranges.last, low <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, high)
            } else {
                ranges.append(low...high)
            }
        }
        return ranges
    }

    /// For each line index, the nearest line strictly above it that reads as a declaration.
    static func nearestDeclarations(_ lines: [DiffLine]) -> [String?] {
        var result: [String?] = []
        result.reserveCapacity(lines.count)
        var current: String?
        for line in lines {
            result.append(current)
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if DiffHunk.isDeclaration(trimmed) { current = trimmed }
        }
        return result
    }

    static func headerText(_ slice: ArraySlice<DiffLine>, declaration: String?) -> String {
        let oldStart = slice.first { $0.oldNumber != nil }?.oldNumber ?? 0
        let newStart = slice.first { $0.newNumber != nil }?.newNumber ?? 0
        let oldCount = slice.count { $0.kind != .added }
        let newCount = slice.count { $0.kind != .removed }
        return "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" + (declaration.map { " " + $0 } ?? "")
    }

    /// Removed lines on the left, added on the right, paired in order; context on both sides.
    static func splitRows(lines: [DiffLine], range: ClosedRange<Int>) -> [Row] {
        var rows: [Row] = []
        var dels: [Int] = []
        var adds: [Int] = []
        func flush() {
            for i in 0..<max(dels.count, adds.count) {
                rows.append(.split(left: i < dels.count ? dels[i] : nil, right: i < adds.count ? adds[i] : nil))
            }
            dels = []
            adds = []
        }
        for index in range {
            switch lines[index].kind {
            case .removed:
                if !adds.isEmpty { flush() }
                dels.append(index)
            case .added: adds.append(index)
            case .context:
                flush()
                rows.append(.split(left: index, right: index))
            }
        }
        flush()
        return rows
    }
}

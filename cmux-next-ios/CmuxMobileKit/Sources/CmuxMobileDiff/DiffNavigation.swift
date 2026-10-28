import Foundation

/// The Mac diff viewer's Next / Previous Hunk and Search (`diffViewerNextHunk`,
/// `diffViewerPreviousHunk`, `diffViewerSearch`) over one file's lines.
public enum DiffNavigation {
    /// Where each run of changed lines starts (a hunk's first added or removed line).
    public static func changeStarts(_ lines: [DiffLine]) -> [Int] {
        lines.indices.filter { index in
            !lines[index].isGap && lines[index].kind != .context
                && (index == 0 || lines[index - 1].kind == .context || lines[index - 1].isGap)
        }
    }

    /// The next (`forward`) or previous start after or before line `current`; from no line,
    /// forward is the first. Nil at either end.
    public static func step(_ starts: [Int], from current: Int?, forward: Bool) -> Int? {
        guard let current else { return forward ? starts.first : nil }
        return forward ? starts.first { $0 > current } : starts.last { $0 < current }
    }

    /// The lines whose text holds `query` (ignoring case and diacritics), in order.
    public static func matches(_ query: String, in lines: [DiffLine]) -> [Int] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return lines.indices.filter { !lines[$0].isGap && lines[$0].text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The character ranges of `query` in `text` (ignoring case and diacritics), for the
    /// match highlight.
    public static func ranges(of query: String, in text: String) -> [Range<Int>] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var result: [Range<Int>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
            let lower = text.distance(from: text.startIndex, to: found.lowerBound)
            result.append(lower..<lower + text.distance(from: found.lowerBound, to: found.upperBound))
            searchStart = found.upperBound > found.lowerBound ? found.upperBound : text.index(after: found.lowerBound)
        }
        return result
    }

    /// The range to show around line `index` when it is inside collapsed context.
    public static func reveal(_ index: Int, lineCount: Int, context: Int = 3) -> ClosedRange<Int> {
        max(0, index - context)...min(lineCount - 1, index + context)
    }
}

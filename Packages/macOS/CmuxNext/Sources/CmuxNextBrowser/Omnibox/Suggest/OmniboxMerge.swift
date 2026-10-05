public import Foundation

/// How late (phase B) rows join the card (plans/cmux-next/omnibar-suggestions.md,
/// "Merge rule"), pure: no row on screen at or above the highlighted row
/// moves; new rows fill free slots below in rank order; when the card is
/// full, a new row replaces only the lowest-ranked row below the highlight,
/// and only when it outranks it. The card never loses a row, so its height
/// never shrinks under the pointer while a generation's results arrive.
public nonisolated struct OmniboxMerge {
    public init() {}

    /// `visible` with `incoming` merged. `highlight` is the highlighted (or
    /// selected) row; `capacity` the card's row limit.
    public static func merge(visible: [BrowserSuggestion], highlight: Int, incoming: [BrowserSuggestion], capacity: Int) -> [BrowserSuggestion] {
        var rows = visible
        // Red: late rows are not merged yet.
        if capacity >= 0 { return rows }
        var keys = Set(rows.map(key))
        let frozen = max(highlight, 0)
        let ranked = incoming.enumerated().sorted { lhs, rhs in
            lhs.element.score != rhs.element.score ? lhs.element.score > rhs.element.score : lhs.offset < rhs.offset
        }.map(\.element)
        for row in ranked {
            let rowKey = key(row)
            guard !keys.contains(rowKey) else { continue }
            if rows.count < capacity {
                rows.append(row)
                keys.insert(rowKey)
                continue
            }
            // The lowest-ranked row below the highlight; the lowest on screen among equals.
            let movable = rows.indices.filter { $0 > frozen }
            guard let victim = movable.min(by: { rows[$0].score != rows[$1].score ? rows[$0].score < rows[$1].score : $0 > $1 }),
                  rows[victim].score < row.score else { continue }
            keys.remove(key(rows[victim]))
            rows[victim] = row
            keys.insert(rowKey)
        }
        return rows
    }

    /// One row per page; one search row per query text.
    static func key(_ row: BrowserSuggestion) -> String {
        row.kind == .search ? "search:" + row.title.lowercased() : BrowserHistoryRanker.dedupeKey(for: row.url)
    }
}

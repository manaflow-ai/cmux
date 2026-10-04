import CmuxNextActions
public import Foundation

/// One ranked row by entry index. Sendable; the main actor maps it to an item.
nonisolated public struct PaletteRankedRow: Sendable, Hashable {
    public let index: Int
    public let score: Int
    /// Scalar offsets into the entry title that matched.
    public let highlights: [Int]
}

/// A group of ranked rows. `sectionIndex` nil is the Recent section.
nonisolated public struct PaletteRankedSection: Sendable, Hashable {
    public let sectionIndex: Int?
    public let rows: [PaletteRankedRow]
}

/// Turns matches into ordered sections. Pure, so it runs on the searcher
/// actor (or synchronously in tests and benchmarks).
///
/// Empty query: a Recent section (top frecency) when the page wants it, then
/// every visible entry grouped by section in section order. Non-empty query:
/// entries scored as match + frecency boost + bias, grouped by section, with
/// sections ordered by their best row (or by section order when the page
/// keeps it) and rows by score.
nonisolated public enum PaletteRanker {
    /// Disabled rows (unbound actions in debug builds) sink below every
    /// enabled match but stay visible.
    static let disabledPenalty = 1_000

    public static func rank(
        index: inout PaletteSearchIndex,
        query: String,
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        keepsSectionOrder: Bool = false,
        ranksPrefixFirst: Bool = false,
        recentLimit: Int = 5,
        rowLimit: Int = 400,
        highlightLimit: Int = 60
    ) -> [PaletteRankedSection] {
        let parsed = FuzzyQuery(query)
        let entries = index.entries
        if parsed.isEmpty {
            return rankEmpty(entries: entries, sectionOrders: sectionOrders, frecency: frecency, now: now,
                             showsRecent: showsRecent, recentLimit: recentLimit)
        }
        let hasHistory = !frecency.entries.isEmpty
        let gated = entries.contains { $0.queryPrefix != nil || $0.hidesWhenTyping }
        var scored: [(index: Int, score: Int)] = index.matches(for: parsed).compactMap { match in
            if gated, entries[match.index].hidesWhenTyping { return nil }
            if gated, let prefix = entries[match.index].queryPrefix, !query.hasPrefix(prefix) { return nil }
            let entry = entries[match.index]
            var score = match.score + entry.rankBias
            if hasHistory, let key = entry.frecencyKey { score += frecency.boost(for: key, at: now) }
            if !entry.isEnabled { score -= Self.disabledPenalty }
            return (match.index, score)
        }
        if ranksPrefixFirst {
            let prefix = query.trimmingCharacters(in: .whitespaces).lowercased()
            let starts = Set(scored.lazy.map { $0.index }.filter { entries[$0].title.lowercased().hasPrefix(prefix) })
            scored.sort { lhs, rhs in
                let left = starts.contains(lhs.index), right = starts.contains(rhs.index)
                if left != right { return left }
                if left { return lhs.index < rhs.index }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
        } else {
            scored.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
        }
        if scored.count > rowLimit { scored.removeLast(scored.count - rowLimit) }

        // Group by section, keeping the global order inside each section.
        var order: [Int] = []
        var rowsBySection: [Int: [PaletteRankedRow]] = [:]
        for (rank, match) in scored.enumerated() {
            let section = entries[match.index].sectionIndex
            let highlights = rank < highlightLimit ? index.highlights(for: match.index, query: parsed) : []
            if rowsBySection[section] == nil { order.append(section) }
            rowsBySection[section, default: []].append(PaletteRankedRow(index: match.index, score: match.score, highlights: highlights))
        }
        if keepsSectionOrder { sortBySectionOrder(&order, sectionOrders) }
        return order.map { PaletteRankedSection(sectionIndex: $0, rows: rowsBySection[$0]!) }
    }

    public static func rankEmpty(
        entries: [PaletteSearchEntry],
        sectionOrders: [Int],
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        recentLimit: Int = 5
    ) -> [PaletteRankedSection] {
        var sections: [PaletteRankedSection] = []
        var recent = Set<Int>()
        if showsRecent, recentLimit > 0, !frecency.entries.isEmpty {
            var positionByKey: [String: Int] = [:]
            for (i, entry) in entries.enumerated() where entry.isEnabled && entry.isVisibleWhenQueryEmpty {
                if let key = entry.frecencyKey, positionByKey[key] == nil { positionByKey[key] = i }
            }
            let rows = frecency.topKeys(limit: recentLimit * 3, at: now)
                .compactMap { positionByKey[$0] }
                .prefix(recentLimit)
                .map { PaletteRankedRow(index: $0, score: 0, highlights: []) }
            if !rows.isEmpty {
                recent = Set(rows.map(\.index))
                sections.append(PaletteRankedSection(sectionIndex: nil, rows: Array(rows)))
            }
        }
        var order: [Int] = []
        var rowsBySection: [Int: [PaletteRankedRow]] = [:]
        for (i, entry) in entries.enumerated() where entry.isVisibleWhenQueryEmpty && !recent.contains(i) {
            if rowsBySection[entry.sectionIndex] == nil { order.append(entry.sectionIndex) }
            rowsBySection[entry.sectionIndex, default: []].append(PaletteRankedRow(index: i, score: 0, highlights: []))
        }
        sortBySectionOrder(&order, sectionOrders)
        sections += order.map { PaletteRankedSection(sectionIndex: $0, rows: rowsBySection[$0]!) }
        return sections
    }

    /// Sorts section indices by their `order`, then by first appearance.
    static func sortBySectionOrder(_ sections: inout [Int], _ sectionOrders: [Int]) {
        let sortKey = { (section: Int) in section < sectionOrders.count ? sectionOrders[section] : Int.max }
        sections.sort { sortKey($0) != sortKey($1) ? sortKey($0) < sortKey($1) : $0 < $1 }
    }
}

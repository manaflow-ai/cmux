public import CmuxNextActions
public import Foundation

/// Prepared search candidates for one page. Built once per item set; each
/// query only scans. A query that extends the previous one (typing another
/// character) scans only the previous matches.
public final class PaletteSearchIndex {
    public let items: [PaletteItem]
    /// Parallel to `items`: whether the item shows for an empty query.
    public let visibleWhenQueryEmpty: [Bool]

    private let fields: [[FuzzyField]]
    private var cache: (query: FuzzyQuery, matches: [Int])?

    /// Field weights in percent.
    static let titleWeight: Int32 = 100
    static let keywordWeight: Int32 = 80
    static let subtitleWeight: Int32 = 65
    static let accessoryWeight: Int32 = 50

    public init(items: [PaletteItem], visibleWhenQueryEmpty: [Bool]? = nil) {
        self.items = items
        self.visibleWhenQueryEmpty = visibleWhenQueryEmpty ?? Array(repeating: true, count: items.count)
        fields = items.map { item in
            var fields = [FuzzyField(FuzzyText(item.title), weight: Self.titleWeight)]
            if !item.keywords.isEmpty {
                fields.append(FuzzyField(FuzzyText(item.keywords.joined(separator: " ")), weight: Self.keywordWeight))
            }
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                fields.append(FuzzyField(FuzzyText(subtitle), weight: Self.subtitleWeight))
            }
            if let accessory = item.accessory, !accessory.isEmpty {
                fields.append(FuzzyField(FuzzyText(accessory), weight: Self.accessoryWeight))
            }
            return fields
        }
    }

    /// Indices and raw match scores (before frecency and bias) for `query`,
    /// in item order.
    public func matches(for query: FuzzyQuery) -> [(index: Int, score: Int)] {
        let candidates: AnySequence<Int>
        if let cache, query.refines(cache.query) {
            candidates = AnySequence(cache.matches)
        } else {
            candidates = AnySequence(items.indices)
        }
        var result: [(index: Int, score: Int)] = []
        for index in candidates {
            if let score = FuzzyMatcher.score(query, fields: fields[index]) {
                result.append((index, score))
            }
        }
        cache = (query, result.map(\.index))
        return result
    }

    /// Title positions to emphasize for `query`.
    public func highlights(for index: Int, query: FuzzyQuery) -> [Int] {
        FuzzyMatcher.matchedPositions(query, in: fields[index][0].text)
    }
}

/// One rendered row.
public struct PaletteRow: Identifiable {
    public let item: PaletteItem
    /// Scalar offsets into `item.title` that matched the query.
    public let highlights: [Int]
    public let score: Int

    public var id: String { item.id }
}

public struct PaletteResultSection: Identifiable {
    public let section: PaletteSection
    public let rows: [PaletteRow]

    public var id: String { section.id }
    public var title: String { section.title }
}

/// Turns matches into ordered sections.
///
/// Empty query: a Recent section (top frecency) when the page wants it, then
/// every visible item grouped by section in provider order. Non-empty query:
/// items scored as match + frecency boost + bias, grouped by section, with
/// sections ordered by their best row and rows by score.
public enum PaletteRanker {
    public static func rank(
        index: PaletteSearchIndex,
        query: String,
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        recentLimit: Int = 5,
        rowLimit: Int = 400,
        highlightLimit: Int = 60
    ) -> [PaletteResultSection] {
        let parsed = FuzzyQuery(query)
        let items = index.items
        if parsed.isEmpty {
            return rankEmpty(index: index, frecency: frecency, now: now, showsRecent: showsRecent, recentLimit: recentLimit)
        }

        var scored: [(index: Int, score: Int)] = index.matches(for: parsed).map { match in
            let item = items[match.index]
            var score = match.score + item.rankBias
            if let key = item.frecencyKey { score += frecency.boost(for: key, at: now) }
            if !item.isEnabled { score -= 40 }
            return (match.index, score)
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }
        if scored.count > rowLimit { scored.removeLast(scored.count - rowLimit) }

        // Group by section, keeping the global order inside each section.
        var order: [String] = []
        var rowsBySection: [String: [PaletteRow]] = [:]
        var sectionByID: [String: PaletteSection] = [:]
        for (rank, entry) in scored.enumerated() {
            let item = items[entry.index]
            let highlights = rank < highlightLimit ? index.highlights(for: entry.index, query: parsed) : []
            let row = PaletteRow(item: item, highlights: highlights, score: entry.score)
            if rowsBySection[item.section.id] == nil {
                order.append(item.section.id)
                sectionByID[item.section.id] = item.section
            }
            rowsBySection[item.section.id, default: []].append(row)
        }
        return order.map { PaletteResultSection(section: sectionByID[$0]!, rows: rowsBySection[$0]!) }
    }

    private static func rankEmpty(
        index: PaletteSearchIndex,
        frecency: FrecencyStore,
        now: Date,
        showsRecent: Bool,
        recentLimit: Int
    ) -> [PaletteResultSection] {
        let items = index.items
        var recentIDs = Set<String>()
        var sections: [PaletteResultSection] = []
        if showsRecent, recentLimit > 0 {
            var positionByKey: [String: Int] = [:]
            for (i, item) in items.enumerated() where item.isEnabled && index.visibleWhenQueryEmpty[i] {
                if let key = item.frecencyKey, positionByKey[key] == nil { positionByKey[key] = i }
            }
            let recentRows = frecency.topKeys(limit: recentLimit * 3, at: now)
                .compactMap { positionByKey[$0] }
                .prefix(recentLimit)
                .map { PaletteRow(item: items[$0], highlights: [], score: 0) }
            if !recentRows.isEmpty {
                recentIDs = Set(recentRows.map(\.id))
                sections.append(PaletteResultSection(section: .recent, rows: Array(recentRows)))
            }
        }
        var order: [PaletteSection] = []
        var rowsBySection: [String: [PaletteRow]] = [:]
        for (i, item) in items.enumerated() where index.visibleWhenQueryEmpty[i] && !recentIDs.contains(item.id) {
            if rowsBySection[item.section.id] == nil { order.append(item.section) }
            rowsBySection[item.section.id, default: []].append(PaletteRow(item: item, highlights: [], score: 0))
        }
        order.sort { $0.order < $1.order }
        sections += order.map { PaletteResultSection(section: $0, rows: rowsBySection[$0.id]!) }
        return sections
    }
}

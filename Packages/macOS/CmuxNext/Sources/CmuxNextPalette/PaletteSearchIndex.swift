public import CmuxNextActions

/// The searchable text and ranking inputs of one item. Sendable, so an
/// index can be built and searched off the main actor.
nonisolated public struct PaletteSearchEntry: Sendable {
    public var title: String
    public var keywords: [String]
    public var subtitle: String?
    public var accessory: String?
    public var rankBias: Int
    public var frecencyKey: String?
    public var isEnabled: Bool
    public var isVisibleWhenQueryEmpty: Bool
    /// Matches only a query with this prefix (`PaletteItem.queryPrefix`).
    public var queryPrefix: String?
    /// Shows for an empty query only (`PaletteItem.hidesWhenTyping`).
    public var hidesWhenTyping = false
    /// Index into the page's section table.
    public var sectionIndex: Int

    public init(
        title: String,
        keywords: [String] = [],
        subtitle: String? = nil,
        accessory: String? = nil,
        rankBias: Int = 0,
        frecencyKey: String? = nil,
        isEnabled: Bool = true,
        isVisibleWhenQueryEmpty: Bool = true,
        queryPrefix: String? = nil,
        sectionIndex: Int = 0
    ) {
        self.title = title
        self.keywords = keywords
        self.subtitle = subtitle
        self.accessory = accessory
        self.rankBias = rankBias
        self.frecencyKey = frecencyKey
        self.isEnabled = isEnabled
        self.isVisibleWhenQueryEmpty = isVisibleWhenQueryEmpty
        self.queryPrefix = queryPrefix
        self.sectionIndex = sectionIndex
    }
}

/// Prepared search candidates for one page: a flat fuzzy corpus plus the
/// ranking inputs. A value type, so the main actor hands a snapshot to the
/// searcher and never shares mutable state. A query that extends the
/// previous one (typing another character) scans only the previous matches.
nonisolated public struct PaletteSearchIndex: Sendable {
    public let entries: [PaletteSearchEntry]
    private let corpus: FuzzyCorpus
    private var cache: (query: FuzzyQuery, matches: [Int])?

    /// Field weights in percent.
    static let titleWeight: Int32 = 100
    static let keywordWeight: Int32 = 80
    static let subtitleWeight: Int32 = 65
    static let accessoryWeight: Int32 = 50

    public init(entries: [PaletteSearchEntry]) {
        self.entries = entries
        var corpus = FuzzyCorpus()
        for entry in entries {
            var fields = [FuzzyField(FuzzyText(entry.title), weight: Self.titleWeight)]
            if !entry.keywords.isEmpty {
                fields.append(FuzzyField(FuzzyText(entry.keywords.joined(separator: " ")), weight: Self.keywordWeight))
            }
            if let subtitle = entry.subtitle, !subtitle.isEmpty {
                fields.append(FuzzyField(FuzzyText(subtitle), weight: Self.subtitleWeight))
            }
            if let accessory = entry.accessory, !accessory.isEmpty {
                fields.append(FuzzyField(FuzzyText(accessory), weight: Self.accessoryWeight))
            }
            corpus.append(fields)
        }
        self.corpus = corpus
    }

    public var count: Int { entries.count }

    /// Indices and raw match scores (before frecency and bias) for `query`,
    /// in entry order.
    public mutating func matches(for query: FuzzyQuery) -> [(index: Int, score: Int)] {
        let result: [(index: Int, score: Int)]
        if let cache, query.refines(cache.query) {
            result = corpus.matches(query, in: cache.matches)
        } else {
            result = corpus.matches(query, in: entries.indices)
        }
        cache = (query, result.map(\.index))
        return result
    }

    /// Title positions to emphasize for `query`.
    public func highlights(for index: Int, query: FuzzyQuery) -> [Int] {
        corpus.matchedPositions(query, candidate: index)
    }
}

extension PaletteSearchIndex {
    /// Builds an index over `items`; sections are numbered in first-seen order.
    @MainActor
    public init(items: [PaletteItem], visibleWhenQueryEmpty: [Bool]? = nil) {
        var sectionIndexByID: [String: Int] = [:]
        let entries = items.enumerated().map { position, item in
            let sectionIndex = sectionIndexByID[item.section.id] ?? {
                let next = sectionIndexByID.count
                sectionIndexByID[item.section.id] = next
                return next
            }()
            return PaletteSearchEntry(item, visible: visibleWhenQueryEmpty?[position] ?? true, sectionIndex: sectionIndex)
        }
        self.init(entries: entries)
    }
}

extension PaletteSearchEntry {
    @MainActor
    init(_ item: PaletteItem, visible: Bool, sectionIndex: Int) {
        self.init(
            title: item.title,
            keywords: item.keywords,
            subtitle: item.subtitle,
            accessory: item.accessory,
            rankBias: item.rankBias,
            frecencyKey: item.frecencyKey,
            isEnabled: item.isEnabled,
            isVisibleWhenQueryEmpty: visible,
            queryPrefix: item.queryPrefix,
            sectionIndex: sectionIndex
        )
        hidesWhenTyping = item.hidesWhenTyping
    }
}

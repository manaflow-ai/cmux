public import CmuxNextActions

/// Prepared search candidates for one page. Built once per item set; each
/// query only scans. A query that extends the previous one (typing another
/// character) scans only the previous matches.
public final class PaletteSearchIndex {
    public let items: [PaletteItem]
    /// Parallel to `items`: whether the item shows for an empty query.
    public let visibleWhenQueryEmpty: [Bool]

    private let corpus: FuzzyCorpus
    /// Per-item ranking inputs, copied out so ranking never copies items.
    let biases: [Int]
    let frecencyKeys: [String?]
    let enabled: [Bool]
    private var cache: (query: FuzzyQuery, matches: [Int])?

    /// Field weights in percent.
    static let titleWeight: Int32 = 100
    static let keywordWeight: Int32 = 80
    static let subtitleWeight: Int32 = 65
    static let accessoryWeight: Int32 = 50

    public init(items: [PaletteItem], visibleWhenQueryEmpty: [Bool]? = nil) {
        self.items = items
        self.visibleWhenQueryEmpty = visibleWhenQueryEmpty ?? Array(repeating: true, count: items.count)
        var corpus = FuzzyCorpus()
        for item in items {
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
            corpus.append(fields)
        }
        self.corpus = corpus
        biases = items.map(\.rankBias)
        frecencyKeys = items.map(\.frecencyKey)
        enabled = items.map(\.isEnabled)
    }

    /// Indices and raw match scores (before frecency and bias) for `query`,
    /// in item order.
    public func matches(for query: FuzzyQuery) -> [(index: Int, score: Int)] {
        let result: [(index: Int, score: Int)]
        if let cache, query.refines(cache.query) {
            result = corpus.matches(query, in: cache.matches)
        } else {
            result = corpus.matches(query, in: items.indices)
        }
        cache = (query, result.map(\.index))
        return result
    }

    /// Title positions to emphasize for `query`.
    public func highlights(for index: Int, query: FuzzyQuery) -> [Int] {
        corpus.matchedPositions(query, candidate: index)
    }
}

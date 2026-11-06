public import Foundation

/// Usage history with exponential decay: each use adds 1, and the total
/// halves every `halfLife`. Frequent and recent items score high; an item
/// used 20 times last month and never since fades behind today's picks.
nonisolated public struct FrecencyStore: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// Decayed use count as of `lastUsed`.
        public var score: Double
        public var lastUsed: Date

        public init(score: Double, lastUsed: Date) {
            self.score = score
            self.lastUsed = lastUsed
        }
    }

    /// A learned pick: the row the user ran for a typed query start
    /// (palette-ranking.md 5.2). The daemon's history learns them; a local
    /// history (an older daemon, tests) learns them the same way with
    /// ``recordPick(_:query:at:)`` and saves them.
    public struct Pick: Codable, Sendable, Equatable {
        /// The normalized query start (lowercased, white space collapsed).
        public var prefix: String
        public var key: String
        /// Decayed pick count as of `lastUsed` (halves every `pickHalfLife`).
        public var score: Double
        public var lastUsed: Date
        /// The latest row picked for `prefix`.
        public var isLast: Bool

        public init(prefix: String, key: String, score: Double, lastUsed: Date, isLast: Bool) {
            self.prefix = prefix
            self.key = key
            self.score = score
            self.lastUsed = lastUsed
            self.isLast = isLast
        }
    }

    public private(set) var entries: [String: Entry]
    public var halfLife: TimeInterval
    /// Oldest entries are dropped beyond this many keys.
    public var capacity: Int
    /// Learned picks, mirrored from the daemon's history (empty for a local history).
    public private(set) var picks: [Pick] = []
    public var pickHalfLife: TimeInterval = 7 * 24 * 60 * 60
    /// Usage keys of rows the user hid (mirrored from the daemon's history).
    public private(set) var hidden: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case entries, halfLife, capacity, picks
    }

    /// Learned picks are kept for query starts of at most this many characters (the daemon's bound).
    public static let pickPrefixCharacters = 8
    /// At most this many query starts keep picks, and this many rows each (the daemon's bounds).
    public static let pickPrefixCapacity = 512
    public static let picksPerPrefix = 8

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([String: Entry].self, forKey: .entries)
        halfLife = try container.decode(TimeInterval.self, forKey: .halfLife)
        capacity = try container.decode(Int.self, forKey: .capacity)
        // A history saved before local picks has none.
        picks = try container.decodeIfPresent([Pick].self, forKey: .picks) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(halfLife, forKey: .halfLife)
        try container.encode(capacity, forKey: .capacity)
        try container.encode(picks, forKey: .picks)
    }

    public init(entries: [String: Entry] = [:], halfLife: TimeInterval = 3 * 24 * 60 * 60, capacity: Int = 500) {
        self.entries = entries
        self.halfLife = halfLife
        self.capacity = capacity
    }

    /// The daemon's whole history replaces this mirror (`palette_usage.get`).
    public mutating func replace(entries: [String: Entry], picks: [Pick], halfLife: TimeInterval, pickHalfLife: TimeInterval,
                                 hidden: Set<String> = []) {
        self.entries = entries
        self.picks = picks
        self.hidden = hidden
        self.halfLife = halfLife
        self.pickHalfLife = pickHalfLife
    }

    /// Reset Ranking for a local history: forgets the row's uses and learned picks.
    public mutating func forget(_ key: String) {
        entries.removeValue(forKey: key)
        let prefixes = Set(picks.filter { $0.key == key && $0.isLast }.map(\.prefix))
        picks.removeAll { $0.key == key }
        // The latest pick of a start whose last row was forgotten is its newest remaining row.
        for prefix in prefixes {
            let newest = picks.indices.filter { picks[$0].prefix == prefix }.max { picks[$0].lastUsed < picks[$1].lastUsed }
            if let newest { picks[newest].isLast = true }
        }
    }

    /// Clear Search History: forgets every use and learned pick. Hidden rows stay hidden (a
    /// person's choice, not history).
    public mutating func clear() {
        entries.removeAll()
        picks.removeAll()
    }

    /// Every row with uses or learned picks.
    public var rowKeys: Set<String> { Set(entries.keys).union(picks.map(\.key)) }

    /// This history with only its hidden rows: what ranks while `palette.searchHistory` is off.
    public func keepingOnlyHidden() -> FrecencyStore {
        var store = self
        store.clear()
        return store
    }

    /// The query as learned picks key it: trimmed, lowercased, inner runs of white space as one
    /// space (the daemon's `normalized_query`).
    public static func normalizedQuery(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// The query starts a pick is recorded under: 1 to ``pickPrefixCharacters`` characters of the
    /// normalized query, trailing white space trimmed, each once (the daemon's `pick_prefixes`).
    public static func pickPrefixes(_ query: String) -> [String] {
        let characters = Array(normalizedQuery(query))
        var seen = Set<String>()
        return (0..<min(characters.count, pickPrefixCharacters)).compactMap { last in
            var prefix = String(characters[...last])
            while prefix.last == " " { prefix.removeLast() }
            return !prefix.isEmpty && seen.insert(prefix).inserted ? prefix : nil
        }
    }

    /// One learned pick of row `key` for `query`, as the daemon records it: each query start's
    /// decayed count of `key` gains 1 (half-life ``pickHalfLife``) and `key` becomes its latest
    /// pick; the least recent rows and starts beyond the bounds are dropped. An empty query
    /// learns nothing.
    public mutating func recordPick(_ key: String, query: String, at now: Date) {
        for prefix in Self.pickPrefixes(query) {
            var rows = picks.indices.filter { picks[$0].prefix == prefix }
            for index in rows { picks[index].isLast = false }
            if let index = rows.first(where: { picks[$0].key == key }) {
                picks[index].score = pickScore(picks[index], at: now) + 1
                picks[index].lastUsed = now
                picks[index].isLast = true
            } else {
                picks.append(Pick(prefix: prefix, key: key, score: 1, lastUsed: now, isLast: true))
                rows.append(picks.count - 1)
            }
            if rows.count > Self.picksPerPrefix, let oldest = rows.filter({ !picks[$0].isLast }).min(by: { picks[$0].lastUsed < picks[$1].lastUsed }) {
                picks.remove(at: oldest)
            }
        }
        let starts = Dictionary(grouping: picks, by: \.prefix).mapValues { $0.map(\.lastUsed).max() ?? .distantPast }
        if starts.count > Self.pickPrefixCapacity {
            let dropped = Set(starts.sorted { $0.value < $1.value }.prefix(starts.count - Self.pickPrefixCapacity).map(\.key))
            picks.removeAll { dropped.contains($0.prefix) }
        }
    }

    private func pickScore(_ pick: Pick, at now: Date) -> Double {
        pick.score * exp2(-max(0, now.timeIntervalSince(pick.lastUsed)) / pickHalfLife)
    }

    public mutating func record(_ key: String, at now: Date) {
        let current = score(for: key, at: now)
        entries[key] = Entry(score: current + 1, lastUsed: now)
        if entries.count > capacity {
            let oldest = entries.min { $0.value.lastUsed < $1.value.lastUsed }?.key
            if let oldest { entries.removeValue(forKey: oldest) }
        }
    }

    /// Decayed score at `now`. Zero for unknown keys.
    public func score(for key: String, at now: Date) -> Double {
        guard let entry = entries[key] else { return 0 }
        let elapsed: Double = max(0, now.timeIntervalSince(entry.lastUsed))
        let decay: Double = exp2(-elapsed / halfLife)
        return entry.score * decay
    }

    /// Ranking bonus added to a match score. Logarithmic and capped so usage
    /// breaks ties and lifts near matches without beating a clearly better
    /// match.
    public func boost(for key: String, at now: Date) -> Int {
        let s = score(for: key, at: now)
        guard s > 0.01 else { return 0 }
        let scaled: Double = 18 * log2(1 + s)
        return min(Self.maximumBoost, Int(scaled.rounded()))
    }

    public static let maximumBoost = 60
}

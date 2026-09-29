public import Foundation

/// Usage history with exponential decay: each use adds 1, and the total
/// halves every `halfLife`. Frequent and recent items score high; an item
/// used 20 times last month and never since fades behind today's picks.
nonisolated public struct FrecencyStore: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// Decayed use count as of `lastUsed`.
        public var score: Double
        public var lastUsed: Date
    }

    public private(set) var entries: [String: Entry]
    public var halfLife: TimeInterval
    /// Oldest entries are dropped beyond this many keys.
    public var capacity: Int

    public init(entries: [String: Entry] = [:], halfLife: TimeInterval = 3 * 24 * 60 * 60, capacity: Int = 500) {
        self.entries = entries
        self.halfLife = halfLife
        self.capacity = capacity
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

    /// Keys ordered by decayed score, highest first.
    public func topKeys(limit: Int, at now: Date, minimumScore: Double = 0.05) -> [String] {
        var scored: [(key: String, score: Double)] = []
        for key in entries.keys {
            let value = score(for: key, at: now)
            if value >= minimumScore { scored.append((key, value)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.key < rhs.key
        }
        return scored.prefix(limit).map(\.key)
    }

    public static let maximumBoost = 60
}

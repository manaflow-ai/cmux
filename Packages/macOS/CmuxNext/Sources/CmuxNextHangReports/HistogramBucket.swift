/// One histogram bucket in milliseconds: `count` values were at least `lowMs` and below `highMs`.
public nonisolated struct HistogramBucket: Codable, Sendable, Equatable {
    /// The longest duration a bucket edge may name (one day).
    public static let maxMs = 86_400_000

    /// The bucket's lower edge, in milliseconds.
    public var lowMs: Int
    /// The bucket's upper edge, in milliseconds.
    public var highMs: Int
    /// How many values fell in it.
    public var count: Int

    /// Makes the value from its parts.
    public init(lowMs: Int, highMs: Int, count: Int) {
        self.lowMs = min(max(0, lowMs), Self.maxMs)
        self.highMs = min(max(self.lowMs, highMs), Self.maxMs)
        self.count = max(0, count)
    }
}

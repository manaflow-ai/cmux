/// Bounded-work accounting returned by the shared Vault JSONL reader.
struct SessionIndexJSONLReadMetrics: Equatable, Sendable {
    let bytesRead: Int
    let recordsVisited: Int
    /// True when a positive `maxBytes` stopped the start scan before EOF.
    /// Callback-terminated scans and nonpositive limits are never marked as
    /// byte-truncated.
    let didReachByteLimit: Bool
    let didReachStart: Bool
    let nextEndOffset: UInt64?

    init(
        bytesRead: Int,
        recordsVisited: Int,
        didReachByteLimit: Bool = false,
        didReachStart: Bool = true,
        nextEndOffset: UInt64? = nil
    ) {
        self.bytesRead = bytesRead
        self.recordsVisited = recordsVisited
        self.didReachByteLimit = didReachByteLimit
        self.didReachStart = didReachStart
        self.nextEndOffset = nextEndOffset
    }
}

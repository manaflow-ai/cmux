/// Bounded-work accounting returned by the shared Vault JSONL reader.
struct SessionIndexJSONLReadMetrics: Equatable, Sendable {
    let bytesRead: Int
    let recordsVisited: Int
    let didReachStart: Bool
    let nextEndOffset: UInt64?

    init(
        bytesRead: Int,
        recordsVisited: Int,
        didReachStart: Bool = true,
        nextEndOffset: UInt64? = nil
    ) {
        self.bytesRead = bytesRead
        self.recordsVisited = recordsVisited
        self.didReachStart = didReachStart
        self.nextEndOffset = nextEndOffset
    }
}

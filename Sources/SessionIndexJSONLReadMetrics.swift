/// Bounded-work accounting returned by the shared Vault JSONL reader.
struct SessionIndexJSONLReadMetrics: Equatable, Sendable {
    let bytesRead: Int
    let recordsVisited: Int
    let didReachStart: Bool
    let didSkipOversizedRecord: Bool
    let didEncounterMalformedRecord: Bool
    let nextEndOffset: UInt64?

    init(
        bytesRead: Int,
        recordsVisited: Int,
        didReachStart: Bool = true,
        didSkipOversizedRecord: Bool = false,
        didEncounterMalformedRecord: Bool = false,
        nextEndOffset: UInt64? = nil
    ) {
        self.bytesRead = bytesRead
        self.recordsVisited = recordsVisited
        self.didReachStart = didReachStart
        self.didSkipOversizedRecord = didSkipOversizedRecord
        self.didEncounterMalformedRecord = didEncounterMalformedRecord
        self.nextEndOffset = nextEndOffset
    }
}

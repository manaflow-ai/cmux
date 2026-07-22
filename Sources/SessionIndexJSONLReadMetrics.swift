/// Bounded-work accounting returned by the shared Vault JSONL reader.
struct SessionIndexJSONLReadMetrics: Equatable, Sendable {
    let bytesRead: Int
    let recordsVisited: Int
}

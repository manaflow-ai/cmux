/// Latest mutations decoded from a bounded journal tail.
struct WorkstreamBoundedLatestResult {
    let items: [WorkstreamItem]
    let exceededBudget: Bool
    let startOffset: UInt64?
}

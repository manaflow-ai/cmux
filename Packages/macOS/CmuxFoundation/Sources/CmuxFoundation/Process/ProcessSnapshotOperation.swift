/// Worker ownership retained until an uninterruptible provider has returned.
struct ProcessSnapshotOperation<Fields: OptionSet & Sendable> {
    let id: UInt64
    let generation: UInt64
    let startedAt: ContinuousClock.Instant
    let fields: Fields
    let task: Task<Void, Never>
    var abandoned = false
}

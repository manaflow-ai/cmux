/// Immutable value and provenance of one process census.
struct ProcessSnapshotCensus<Snapshot: Sendable, Fields: OptionSet & Sendable> {
    let value: Snapshot
    let fields: Fields
    let generation: UInt64
    let startedAt: ContinuousClock.Instant
}

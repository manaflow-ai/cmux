/// One consumer's fields, freshness boundary, and cancellable completion.
struct ProcessSnapshotWaiter<Snapshot: Sendable, Fields: OptionSet & Sendable> {
    let fields: Fields
    let minimumGeneration: UInt64
    let maximumAge: Duration?
    let continuation: CheckedContinuation<Snapshot, any Error>

    func accepts(_ census: ProcessSnapshotCensus<Snapshot, Fields>, at now: ContinuousClock.Instant) -> Bool {
        census.generation >= minimumGeneration &&
            maximumAge.map { census.startedAt.duration(to: now) <= $0 } != false
    }
}

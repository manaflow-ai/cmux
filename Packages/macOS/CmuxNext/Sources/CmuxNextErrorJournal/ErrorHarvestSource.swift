/// A place the journal reads problems from on each harvest (a log file, the unified log,
/// crash reports). The journal keeps each source's cursor between harvests and launches.
public protocol ErrorHarvestSource: Sendable {
    /// Stable id; keys the saved cursor.
    var id: String { get }
    /// Returns the problems written after `cursor` (nil: the first harvest ever) and the new cursor.
    ///
    /// A long read checks `Task.isCancelled` as it goes and, once cancelled, returns what it read
    /// so far with the cursor at its last entry (not `CancellationError`): the quit and
    /// `errors.list` cancel a harvest at their limits and keep that part.
    func collect(after cursor: String?) async throws -> ErrorHarvest
}

/// What one source returned.
public struct ErrorHarvest: Sendable, Equatable {
    /// The new problems.
    public var events: [ErrorEvent]
    /// Where the next harvest starts; nil keeps the old cursor.
    public var cursor: String?
    /// The source stopped at its per-read bound with entries left after ``cursor``: the journal
    /// reads it again from there in the same harvest (unless the harvest is cancelled).
    public var more: Bool

    /// Makes a harvest result.
    /// - Parameters:
    ///   - events: The new problems.
    ///   - cursor: Where the next read starts; nil keeps the old cursor.
    ///   - more: Entries are left after `cursor` (the read stopped at its bound); false by default.
    public init(events: [ErrorEvent], cursor: String?, more: Bool = false) {
        self.events = events
        self.cursor = cursor
        self.more = more
    }
}

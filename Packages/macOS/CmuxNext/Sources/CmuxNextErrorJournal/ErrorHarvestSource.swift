/// A place the journal reads problems from on each harvest (a log file, the unified log,
/// crash reports). The journal keeps each source's cursor between harvests and launches.
public protocol ErrorHarvestSource: Sendable {
    /// Stable id; keys the saved cursor.
    var id: String { get }
    /// Returns the problems written after `cursor` (nil: the first harvest ever) and the new cursor.
    func collect(after cursor: String?) async throws -> ErrorHarvest
}

/// What one source returned.
public struct ErrorHarvest: Sendable, Equatable {
    /// The new problems.
    public var events: [ErrorEvent]
    /// Where the next harvest starts; nil keeps the old cursor.
    public var cursor: String?

    /// Makes a harvest result.
    public init(events: [ErrorEvent], cursor: String?) {
        self.events = events
        self.cursor = cursor
    }
}

/// A place the journal reads problems from on each harvest (a log file, the unified log,
/// crash reports). The journal keeps each source's cursor between harvests and launches.
public protocol ErrorHarvestSource: Sendable {
    /// Stable id; keys the saved cursor.
    var id: String { get }
    /// Whether a change to a file or folder on disk announces this source's new problems, so a
    /// reader may skip it until a watch sees one. False for the unified log, which has no such
    /// signal: every scheduled harvest reads it.
    var announcesChanges: Bool { get }
    /// Returns the problems written after `cursor` (nil: the first harvest ever) and the new cursor.
    func collect(after cursor: String?) async throws -> ErrorHarvest
}

extension ErrorHarvestSource {
    /// Files and folders on disk: a watch on them sees each change.
    public var announcesChanges: Bool { true }
}

/// What one source returned.
public struct ErrorHarvest: Sendable, Equatable {
    /// The new problems.
    public var events: [ErrorEvent]
    /// Where the next harvest starts; nil keeps the old cursor.
    public var cursor: String?
    /// The source stopped at the bound of one harvest: more is written after ``cursor``, and no
    /// new change will announce it.
    public var more: Bool

    /// Makes a harvest result.
    public init(events: [ErrorEvent], cursor: String?, more: Bool = false) {
        self.events = events
        self.cursor = cursor
        self.more = more
    }
}

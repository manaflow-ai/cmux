public import Foundation

/// The version-stamped record of the classic migration, kept in cmux-next's own folder.
///
/// It is the only marker: classic's files are never written. Each workspace is
/// recorded before it is made, again once made and once done, so a migration
/// cut off midway resumes without duplicates. A ledger with a newer
/// ``schema`` than this build knows (a newer cmux-next ran, then an older one)
/// stops automatic migration rather than guess.
public nonisolated struct ClassicMigrationLedger: Codable, Equatable, Sendable {
    /// The schema this build writes.
    public static let currentSchema = 1

    /// Where a migration run is.
    public nonisolated enum State: String, Codable, Sendable {
        /// A run started and has not finished (the app quit or crashed midway).
        case inProgress
        /// The last run finished.
        case completed
    }

    /// One classic workspace's progress.
    public nonisolated struct Entry: Codable, Equatable, Sendable {
        public nonisolated enum Stage: String, Codable, Sendable {
            /// About to be made; no cmux-next workspace yet.
            case pending
            /// Its cmux-next workspace exists; its layout may be partial.
            case created
            /// Fully made.
            case done
            /// Never comes over (a Cloud VM workspace); ``Entry/reason`` says why.
            case skipped
        }

        public var stage: Stage
        /// The cmux-next workspace made for it, once ``Stage/created``.
        public var nextWorkspace: String?
        public var reason: String?

        public init(stage: Stage, nextWorkspace: String? = nil, reason: String? = nil) {
            self.stage = stage
            self.nextWorkspace = nextWorkspace
            self.reason = reason
        }
    }

    public var schema: Int
    public var state: State
    /// The classic save the last run read.
    public var source: ClassicMigrationSource?
    /// Progress by classic workspace key (``ClassicSessionWorkspace/key``).
    public var workspaces: [String: Entry]
    /// cmux-next group id by classic group id.
    public var groups: [String: String]
    /// How many runs started (first migration, resumes and merges).
    public var runs: Int
    /// The cmux-next version that wrote it last.
    public var appVersion: String?
    public var updatedAt: Double

    public init(schema: Int = Self.currentSchema, state: State = .inProgress, source: ClassicMigrationSource? = nil,
                workspaces: [String: Entry] = [:], groups: [String: String] = [:], runs: Int = 0,
                appVersion: String? = nil, updatedAt: Double = 0) {
        self.schema = schema
        self.state = state
        self.source = source
        self.workspaces = workspaces
        self.groups = groups
        self.runs = runs
        self.appVersion = appVersion
        self.updatedAt = updatedAt
    }
}

/// What ``ClassicMigrationRepository/load()`` found.
public nonisolated enum ClassicMigrationLedgerLoad: Equatable, Sendable {
    /// No migration ran on this Mac for this build's channel.
    case none
    case ledger(ClassicMigrationLedger)
    /// A ledger from a newer cmux-next schema; it is left as it is.
    case newer(schema: Int)
    /// A ledger that does not decode; it was moved aside.
    case unreadable
}

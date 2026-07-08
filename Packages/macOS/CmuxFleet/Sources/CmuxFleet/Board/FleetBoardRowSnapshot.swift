public import Foundation

/// A value snapshot for one Fleet board row.
public struct FleetBoardRowSnapshot: Equatable, Sendable, Identifiable {
    /// The Fleet task identifier.
    public var id: FleetTaskID

    /// The task title.
    public var title: String

    /// The Fleet supervision state.
    public var state: FleetTaskState

    /// The number of agent launch attempts.
    public var attempts: Int

    /// The pull request URL, when available.
    public var prURL: URL?

    /// A compact pull request label, such as `#123`.
    public var prLabel: String?

    /// The latest error message, when available.
    public var lastError: String?

    /// The task's last update timestamp.
    public var updatedAt: Date

    /// Indicates whether retry is currently valid.
    public var canRetry: Bool

    /// Indicates whether cancel is currently valid.
    public var canCancel: Bool

    /// Indicates whether the task has a workspace target to open.
    public var hasWorkspace: Bool

    /// Creates a Fleet board row snapshot.
    public init(
        id: FleetTaskID,
        title: String,
        state: FleetTaskState,
        attempts: Int,
        prURL: URL?,
        prLabel: String?,
        lastError: String?,
        updatedAt: Date,
        canRetry: Bool,
        canCancel: Bool,
        hasWorkspace: Bool
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.attempts = attempts
        self.prURL = prURL
        self.prLabel = prLabel
        self.lastError = lastError
        self.updatedAt = updatedAt
        self.canRetry = canRetry
        self.canCancel = canCancel
        self.hasWorkspace = hasWorkspace
    }
}

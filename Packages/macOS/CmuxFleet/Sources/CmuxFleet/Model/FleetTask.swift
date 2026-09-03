public import Foundation

/// Stores Fleet's normalized snapshot for one source task.
public struct FleetTask: Equatable, Codable, Sendable, Identifiable {
    /// The stable source key, such as `github:owner/repo#123` or `local:<uuid>`.
    public var id: FleetTaskID

    /// The kind of source that produced the task.
    public var sourceKind: FleetTaskSourceKind

    /// The source-native key without Fleet's typed wrapper.
    public var key: String

    /// The source title shown by later Fleet UI surfaces.
    public var title: String

    /// The source body or prompt text.
    public var body: String

    /// The source URL, when the task has one.
    public var url: URL?

    /// The labels mirrored from the source.
    public var labels: [String]

    /// The scheduling priority; lower values run first and `nil` sorts last.
    public var priority: Int?

    /// The source-native state string reserved for source reconcilers.
    public var sourceState: String

    /// Indicates whether scheduler dispatch should skip the task.
    public var isBlocked: Bool

    /// The time the source task was created.
    public var createdAt: Date

    /// The time the normalized snapshot was last updated.
    public var updatedAt: Date

    /// Fleet's current supervision state for the task.
    public var state: FleetTaskState

    /// The number of agent launch attempts already started.
    public var attempts: Int

    /// The cmux workspace identifier attached to the task, when provisioned.
    public var workspaceID: String?

    /// The cmux surface identifier attached to the task, when launched.
    public var surfaceID: String?

    /// The task working directory path, when provisioned.
    public var directoryPath: String?

    /// The branch name assigned to the task, when known.
    public var branch: String?

    /// The pull request handoff snapshot, when one has appeared.
    public var pr: FleetPullRequestStatus?

    /// The most recent recoverable or terminal error message.
    public var lastError: String?

    /// The last supervision activity timestamp observed by Fleet.
    public var lastActivityAt: Date?

    /// Creates a normalized Fleet task snapshot.
    /// - Parameters:
    ///   - id: The stable source key.
    ///   - sourceKind: The kind of source that produced the task.
    ///   - key: The source-native key without Fleet's typed wrapper.
    ///   - title: The source title shown by later Fleet UI surfaces.
    ///   - body: The source body or prompt text.
    ///   - url: The source URL, when the task has one.
    ///   - labels: The labels mirrored from the source.
    ///   - priority: The scheduling priority; lower values run first.
    ///   - sourceState: The source-native state string reserved for source reconcilers.
    ///   - isBlocked: Whether scheduler dispatch should skip the task.
    ///   - createdAt: The time the source task was created.
    ///   - updatedAt: The time the normalized snapshot was last updated.
    ///   - state: Fleet's current supervision state.
    ///   - attempts: The number of agent launch attempts already started.
    ///   - workspaceID: The cmux workspace identifier attached to the task.
    ///   - surfaceID: The cmux surface identifier attached to the task.
    ///   - directoryPath: The task working directory path.
    ///   - branch: The branch name assigned to the task.
    ///   - pr: The pull request handoff snapshot.
    ///   - lastError: The most recent recoverable or terminal error message.
    ///   - lastActivityAt: The last supervision activity timestamp observed by Fleet.
    public init(
        id: FleetTaskID,
        sourceKind: FleetTaskSourceKind,
        key: String,
        title: String,
        body: String,
        url: URL? = nil,
        labels: [String] = [],
        priority: Int? = nil,
        sourceState: String,
        isBlocked: Bool = false,
        createdAt: Date,
        updatedAt: Date,
        state: FleetTaskState = .queued,
        attempts: Int = 0,
        workspaceID: String? = nil,
        surfaceID: String? = nil,
        directoryPath: String? = nil,
        branch: String? = nil,
        pr: FleetPullRequestStatus? = nil,
        lastError: String? = nil,
        lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.key = key
        self.title = title
        self.body = body
        self.url = url
        self.labels = labels
        self.priority = priority
        self.sourceState = sourceState
        self.isBlocked = isBlocked
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.attempts = attempts
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.directoryPath = directoryPath
        self.branch = branch
        self.pr = pr
        self.lastError = lastError
        self.lastActivityAt = lastActivityAt
    }
}

/// Pull-request metadata attached to a Fleet task.
public struct ControlFleetTaskPullRequest: Sendable, Equatable {
    /// The pull-request URL, if one exists.
    public var url: String?
    /// The provider-specific pull-request status.
    public var status: String

    /// Creates Fleet task pull-request metadata.
    ///
    /// - Parameters:
    ///   - url: The pull-request URL, if one exists.
    ///   - status: The provider-specific pull-request status.
    public init(url: String?, status: String) {
        self.url = url
        self.status = status
    }
}

/// A read-only summary of one Fleet task.
///
/// The app target exposes this value through ``ControlFleetContext`` and the
/// coordinator converts it to Fleet task wire payloads.
public struct ControlFleetTaskSnapshot: Sendable, Equatable {
    /// The stable task identifier on the wire.
    public var taskID: String
    /// The owning Fleet identifier.
    public var fleetID: String
    /// The source that created the task, such as `local` or `github`.
    public var source: String
    /// The task title.
    public var title: String
    /// The current task state.
    public var state: ControlFleetTaskStateName
    /// Whether the task is blocked.
    public var isBlocked: Bool
    /// The number of attempts made for this task.
    public var attempts: Int
    /// The optional scheduling priority.
    public var priority: Int?
    /// Labels associated with the task.
    public var labels: [String]
    /// The source URL, if any.
    public var url: String?
    /// The workspace id associated with this task, if any.
    public var workspaceID: String?
    /// The surface id associated with this task, if any.
    public var surfaceID: String?
    /// The working directory associated with this task, if any.
    public var directoryPath: String?
    /// The branch associated with this task, if any.
    public var branch: String?
    /// Pull-request metadata, if any.
    public var pullRequest: ControlFleetTaskPullRequest?
    /// The most recent task error, if any.
    public var lastError: String?
    /// Creation time as Unix seconds.
    public var createdAt: Double
    /// Last update time as Unix seconds.
    public var updatedAt: Double

    /// Creates a Fleet task summary snapshot.
    ///
    /// - Parameters:
    ///   - taskID: The stable task identifier on the wire.
    ///   - fleetID: The owning Fleet identifier.
    ///   - source: The source that created the task.
    ///   - title: The task title.
    ///   - state: The current task state.
    ///   - isBlocked: Whether the task is blocked.
    ///   - attempts: The number of attempts made for this task.
    ///   - priority: The optional scheduling priority.
    ///   - labels: Labels associated with the task.
    ///   - url: The source URL, if any.
    ///   - workspaceID: The workspace id associated with this task, if any.
    ///   - surfaceID: The surface id associated with this task, if any.
    ///   - directoryPath: The working directory associated with this task, if any.
    ///   - branch: The branch associated with this task, if any.
    ///   - pullRequest: Pull-request metadata, if any.
    ///   - lastError: The most recent task error, if any.
    ///   - createdAt: Creation time as Unix seconds.
    ///   - updatedAt: Last update time as Unix seconds.
    public init(
        taskID: String,
        fleetID: String,
        source: String,
        title: String,
        state: ControlFleetTaskStateName,
        isBlocked: Bool,
        attempts: Int,
        priority: Int?,
        labels: [String],
        url: String?,
        workspaceID: String?,
        surfaceID: String?,
        directoryPath: String?,
        branch: String?,
        pullRequest: ControlFleetTaskPullRequest?,
        lastError: String?,
        createdAt: Double,
        updatedAt: Double
    ) {
        self.taskID = taskID
        self.fleetID = fleetID
        self.source = source
        self.title = title
        self.state = state
        self.isBlocked = isBlocked
        self.attempts = attempts
        self.priority = priority
        self.labels = labels
        self.url = url
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.directoryPath = directoryPath
        self.branch = branch
        self.pullRequest = pullRequest
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

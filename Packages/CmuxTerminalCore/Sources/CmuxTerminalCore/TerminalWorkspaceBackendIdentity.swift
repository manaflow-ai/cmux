/// The backend identity that ties a terminal workspace to a cmux task run.
public struct TerminalWorkspaceBackendIdentity: Codable, Equatable, Sendable {
    /// The team identifier that owns the task.
    public var teamID: String
    /// The task identifier.
    public var taskID: String
    /// The task-run identifier.
    public var taskRunID: String
    /// The backend workspace name.
    public var workspaceName: String
    /// A human-readable descriptor for the workspace.
    public var descriptor: String

    /// Creates a backend identity.
    /// - Parameters:
    ///   - teamID: The team identifier.
    ///   - taskID: The task identifier.
    ///   - taskRunID: The task-run identifier.
    ///   - workspaceName: The backend workspace name.
    ///   - descriptor: A human-readable descriptor.
    public init(
        teamID: String,
        taskID: String,
        taskRunID: String,
        workspaceName: String,
        descriptor: String
    ) {
        self.teamID = teamID
        self.taskID = taskID
        self.taskRunID = taskRunID
        self.workspaceName = workspaceName
        self.descriptor = descriptor
    }
}

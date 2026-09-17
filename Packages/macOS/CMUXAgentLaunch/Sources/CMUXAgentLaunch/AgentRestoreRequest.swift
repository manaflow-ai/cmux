/// Structured input for planning one restored process.
public struct AgentRestoreRequest: Equatable, Sendable {
    /// The restore construction mode.
    public let mode: AgentRestoreRequestMode
    /// The agent or binding kind.
    public let kind: String
    /// The persisted checkpoint/session identifier.
    public let checkpointID: String?
    /// The binding source.
    public let source: String?
    /// The restore working directory.
    public let workingDirectory: String?
    /// Environment values persisted on the binding.
    public let environment: [String: String]
    /// The structured launch capture, when available.
    public let launchCommand: AgentLaunchCommand?
    /// A typed argv fallback for registry-owned/custom agents.
    public let preparedArguments: [String]?
    /// The working directory substituted into ``preparedArguments`` when they were built.
    public let preparedArgumentsWorkingDirectory: String?
    /// The last observed Claude permission mode.
    public let observedPermissionMode: String?

    /// Creates a structured restore request.
    public init(
        mode: AgentRestoreRequestMode,
        kind: String,
        checkpointID: String?,
        source: String?,
        workingDirectory: String?,
        environment: [String: String],
        launchCommand: AgentLaunchCommand?,
        preparedArguments: [String]?,
        preparedArgumentsWorkingDirectory: String? = nil,
        observedPermissionMode: String?
    ) {
        self.mode = mode
        self.kind = kind
        self.checkpointID = checkpointID
        self.source = source
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.launchCommand = launchCommand
        self.preparedArguments = preparedArguments
        self.preparedArgumentsWorkingDirectory = preparedArgumentsWorkingDirectory
        self.observedPermissionMode = observedPermissionMode
    }
}

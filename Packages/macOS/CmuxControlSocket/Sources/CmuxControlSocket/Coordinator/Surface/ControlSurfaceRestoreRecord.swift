/// Structured data consumed by `cmux restore`.
///
/// `legacyCommand` is populated only for command-only records written by older
/// builds. New records keep argv and environment structured through process
/// replacement.
public struct ControlSurfaceRestoreRecord: Sendable, Equatable {
    /// The raw `AgentRestoreRequestMode` value consumed by the CLI package.
    public let modeRawValue: String
    /// The persisted agent or binding kind.
    public let kind: String
    /// The persisted session or checkpoint identifier.
    public let checkpointID: String?
    /// The subsystem that created the binding.
    public let source: String?
    /// The directory the restored process should enter before execution.
    public let workingDirectory: String?
    /// Replay-safe environment values persisted on the binding.
    public let environment: [String: String]
    /// The structured launch capture, when available.
    public let launchCommand: ControlAgentLaunchCommand?
    /// Registry-built process arguments used when no captured launch can rebuild them.
    public let preparedArguments: [String]?
    /// The cwd against which `preparedArguments` was captured and may be retargeted.
    public let preparedArgumentsWorkingDirectory: String?
    /// The last observed provider permission mode.
    public let permissionMode: String?
    /// Compatibility shell input retained for records persisted by older builds.
    public let legacyCommand: String?

    /// Creates the structured restore record transported to `cmux restore`.
    ///
    /// - Parameters:
    ///   - modeRawValue: The raw restore construction mode.
    ///   - kind: The persisted agent or binding kind.
    ///   - checkpointID: The persisted session or checkpoint identifier.
    ///   - source: The subsystem that created the binding.
    ///   - workingDirectory: The target restore working directory.
    ///   - environment: Replay-safe persisted environment values.
    ///   - launchCommand: The structured launch capture.
    ///   - preparedArguments: Registry-built fallback process arguments.
    ///   - preparedArgumentsWorkingDirectory: The cwd embedded in prepared arguments.
    ///   - permissionMode: The last observed provider permission mode.
    ///   - legacyCommand: Compatibility input for records written by older builds.
    public init(
        modeRawValue: String,
        kind: String,
        checkpointID: String?,
        source: String?,
        workingDirectory: String?,
        environment: [String: String],
        launchCommand: ControlAgentLaunchCommand?,
        preparedArguments: [String]?,
        preparedArgumentsWorkingDirectory: String?,
        permissionMode: String?,
        legacyCommand: String?
    ) {
        self.modeRawValue = modeRawValue
        self.kind = kind
        self.checkpointID = checkpointID
        self.source = source
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.launchCommand = launchCommand
        self.preparedArguments = preparedArguments
        self.preparedArgumentsWorkingDirectory = preparedArgumentsWorkingDirectory
        self.permissionMode = permissionMode
        self.legacyCommand = legacyCommand
    }
}

/// Structured data consumed by `cmux restore` and `cmux fork`.
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
    /// Registry- or provider-built process arguments used by `cmux fork`.
    public let forkArguments: [String]?
    /// The cwd against which `forkArguments` was captured and may be retargeted.
    public let forkArgumentsWorkingDirectory: String?
    /// The last observed provider permission mode.
    public let permissionMode: String?
    /// Compatibility shell input retained for records persisted by older builds.
    public let legacyCommand: String?
    /// Compatibility fork command retained when structured fork argv is unavailable.
    public let legacyForkCommand: String?

    /// The wire-facing name for ``legacyForkCommand``.
    public var forkCommand: String? { legacyForkCommand }

    /// Creates the structured restore record transported to `cmux restore` or `cmux fork`.
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
    ///   - forkArguments: Provider- or registry-built fork process arguments.
    ///   - forkArgumentsWorkingDirectory: The cwd embedded in fork arguments.
    ///   - permissionMode: The last observed provider permission mode.
    ///   - legacyCommand: Compatibility input for records written by older builds.
    ///   - legacyForkCommand: Compatibility fork input for older or non-structured records.
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
        legacyCommand: String?,
        forkArguments: [String]? = nil,
        forkArgumentsWorkingDirectory: String? = nil,
        legacyForkCommand: String? = nil
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
        self.forkArguments = forkArguments
        self.forkArgumentsWorkingDirectory = forkArgumentsWorkingDirectory
        self.permissionMode = permissionMode
        self.legacyCommand = legacyCommand
        self.legacyForkCommand = legacyForkCommand
    }
}

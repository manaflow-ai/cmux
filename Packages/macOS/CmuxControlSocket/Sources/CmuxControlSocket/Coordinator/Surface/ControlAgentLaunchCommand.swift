/// A structured launch capture transported by the surface-resume socket API.
public struct ControlAgentLaunchCommand: Sendable, Equatable {
    /// The registry-owned launcher identifier, when one created the command.
    public let launcher: String?
    /// The id of the user-declared external launcher that started the agent, when one was detected.
    public let externalLauncher: String?
    /// The captured absolute executable path, when available.
    public let executablePath: String?
    /// Process arguments including `argv[0]`.
    public let arguments: [String]
    /// The working directory captured with the launch.
    public let workingDirectory: String?
    /// Replay-safe environment values captured with the launch.
    public let environment: [String: String]?
    /// The launch home retained for provider-state verification only.
    public let verificationHome: String?
    /// The Unix timestamp at which the launch was captured.
    public let capturedAt: Double?
    /// The subsystem that captured the launch.
    public let source: String?
    /// The outer launcher argv that started the agent, when one was captured.
    public let launcherPrefix: [String]?

    /// Creates a structured launch capture for socket transport.
    ///
    /// - Parameters:
    ///   - launcher: The registry-owned launcher identifier.
    ///   - externalLauncher: The id of the user-declared external launcher that started the agent.
    ///   - executablePath: The captured absolute executable path.
    ///   - arguments: Process arguments including `argv[0]`.
    ///   - workingDirectory: The captured working directory.
    ///   - environment: Replay-safe captured environment values.
    ///   - verificationHome: The launch home used only for provider-state verification.
    ///   - capturedAt: The capture time as a Unix timestamp.
    ///   - source: The subsystem that captured the launch.
    ///   - launcherPrefix: The outer launcher argv, when one was captured.
    public init(
        launcher: String?,
        externalLauncher: String? = nil,
        executablePath: String?,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        verificationHome: String? = nil,
        capturedAt: Double?,
        source: String?,
        launcherPrefix: [String]? = nil
    ) {
        self.launcher = launcher
        self.externalLauncher = externalLauncher
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.verificationHome = verificationHome
        self.capturedAt = capturedAt
        self.source = source
        self.launcherPrefix = launcherPrefix
    }
}

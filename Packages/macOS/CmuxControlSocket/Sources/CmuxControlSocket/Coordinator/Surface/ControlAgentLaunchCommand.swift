/// A structured launch capture transported by the surface-resume socket API.
public struct ControlAgentLaunchCommand: Sendable, Equatable {
    /// The registry-owned launcher identifier, when one created the command.
    public let launcher: String?
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

    /// Creates a structured launch capture for socket transport.
    ///
    /// - Parameters:
    ///   - launcher: The registry-owned launcher identifier.
    ///   - executablePath: The captured absolute executable path.
    ///   - arguments: Process arguments including `argv[0]`.
    ///   - workingDirectory: The captured working directory.
    ///   - environment: Replay-safe captured environment values.
    ///   - verificationHome: The launch home used only for provider-state verification.
    ///   - capturedAt: The capture time as a Unix timestamp.
    ///   - source: The subsystem that captured the launch.
    public init(
        launcher: String?,
        executablePath: String?,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?,
        verificationHome: String? = nil,
        capturedAt: Double?,
        source: String?
    ) {
        self.launcher = launcher
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.verificationHome = verificationHome
        self.capturedAt = capturedAt
        self.source = source
    }
}

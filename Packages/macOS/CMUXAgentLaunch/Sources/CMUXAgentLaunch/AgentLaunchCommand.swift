import Foundation

/// A captured agent launch kept as structured values for later resume planning.
public struct AgentLaunchCommand: Codable, Equatable, Sendable {
    /// The cmux launcher classification, when one was captured.
    public var launcher: String?
    /// The captured executable path.
    public var executablePath: String?
    /// The captured process arguments, including `argv[0]`.
    public var arguments: [String]
    /// The working directory at initial launch.
    public var workingDirectory: String?
    /// Replay-safe environment captured with the launch.
    public var environment: [String: String]?
    /// The launch user's home directory, retained only to resolve provider
    /// state during verification. It is not replayed as an environment override.
    public var verificationHome: String?
    /// The capture timestamp.
    public var capturedAt: TimeInterval?
    /// The capture source.
    public var source: String?

    /// Creates a structured captured launch.
    ///
    /// - Parameters:
    ///   - launcher: The cmux launcher classification, when one was captured.
    ///   - executablePath: The captured executable path.
    ///   - arguments: The captured process arguments, including `argv[0]`.
    ///   - workingDirectory: The working directory at initial launch.
    ///   - environment: Replay-safe environment captured with the launch.
    ///   - verificationHome: The launch home used only for provider-state verification.
    ///   - capturedAt: The capture timestamp.
    ///   - source: The capture source.
    public init(
        launcher: String? = nil,
        executablePath: String? = nil,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        verificationHome: String? = nil,
        capturedAt: TimeInterval? = nil,
        source: String? = nil
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

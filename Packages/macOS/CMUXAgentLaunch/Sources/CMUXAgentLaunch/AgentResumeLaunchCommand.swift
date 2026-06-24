import Foundation

/// The captured launch-command fields ``AgentResumeCommandBuilder`` reads when
/// assembling a resume/fork command, decoupled from the app-side persisted
/// `AgentLaunchCommandSnapshot` Codable struct.
///
/// The builder only reads the launcher token, executable path, argument vector,
/// captured working directory, and captured environment; the snapshot's
/// persistence-only fields (`capturedAt`, `source`) and its `Codable` wire
/// shape stay app-side. The app forwarder maps an `AgentLaunchCommandSnapshot`
/// onto this value so the package does not duplicate the wire type.
public struct AgentResumeLaunchCommand: Sendable, Equatable {
    /// The cmux launcher token (e.g. `"omo"`, `"claudeTeams"`), or `nil` when
    /// the agent was launched directly.
    public let launcher: String?

    /// The captured executable path, or `nil` to fall back to the argv/default.
    public let executablePath: String?

    /// The captured argument vector (executable plus its arguments).
    public let arguments: [String]

    /// The captured working directory the agent launched from, if any.
    public let workingDirectory: String?

    /// The captured launch environment, filtered by
    /// ``AgentLaunchEnvironmentPolicy`` before re-export.
    public let environment: [String: String]?

    /// Creates a launch-command value from the fields the resume builder reads.
    public init(
        launcher: String?,
        executablePath: String?,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]?
    ) {
        self.launcher = launcher
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

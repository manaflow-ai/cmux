public import CMUXAgentLaunch
public import Foundation

/// Immutable, validated metadata for one Amp thread captured by cmux's session extension.
public struct AmpHookSessionSnapshot: Hashable, Sendable {
    /// Amp's native thread identifier.
    public let sessionID: String

    /// The extension-observed thread title, or `nil` when Amp has not assigned one.
    public let title: String?

    /// The normalized working directory recorded for the thread.
    public let workingDirectory: String?

    /// A trusted native Amp launch capture suitable for constructing a resume command.
    public let launchCommand: AgentLaunchCommand?

    /// The latest recorded activity time for the thread.
    public let modified: Date

    /// Creates an immutable Amp thread snapshot.
    ///
    /// - Parameters:
    ///   - sessionID: Amp's native thread identifier.
    ///   - title: The normalized thread title.
    ///   - workingDirectory: The normalized working directory.
    ///   - launchCommand: A validated Amp launch capture.
    ///   - modified: The latest recorded activity time.
    public init(
        sessionID: String,
        title: String?,
        workingDirectory: String?,
        launchCommand: AgentLaunchCommand?,
        modified: Date
    ) {
        self.sessionID = sessionID
        self.title = title
        self.workingDirectory = workingDirectory
        self.launchCommand = launchCommand
        self.modified = modified
    }
}

public import Foundation

/// The resolved session-index drag payload a workspace drop spawns a brand-new
/// terminal from, mirroring the two fields the legacy ``handleSessionDrop`` read
/// off the app-target `SessionEntry`.
///
/// The session-index drag carries a `UUID` in the bonsplit tab payload; when the
/// workspace consumes it from its drag registry it resolves the live
/// `SessionEntry` and projects the two values the drop needs into this Sendable
/// struct, so ``WorkspaceDropCoordinator`` can route the drop without importing
/// the app-target entry type. The legacy body required a non-`nil`
/// `resumeCommand` (it returned `false` otherwise); the host produces this
/// payload only when that guard passes, carrying the already-resolved command.
public struct WorkspaceSessionDropPayload: Sendable, Equatable {
    /// The agent resume command to launch the new terminal with, already
    /// confirmed non-`nil` by the host (legacy `entry.resumeCommand`). The
    /// coordinator appends the legacy trailing newline before launch.
    public let resumeCommand: String

    /// The working directory the resumed session should start in, or `nil` when
    /// the session recorded none (legacy `entry.resumeWorkingDirectory`).
    public let resumeWorkingDirectory: String?

    /// Creates a session drop payload.
    /// - Parameters:
    ///   - resumeCommand: the agent resume command (non-`nil`).
    ///   - resumeWorkingDirectory: the session working directory, or `nil`.
    public init(resumeCommand: String, resumeWorkingDirectory: String?) {
        self.resumeCommand = resumeCommand
        self.resumeWorkingDirectory = resumeWorkingDirectory
    }
}

public import Foundation

/// The resolved startup-command inputs a terminal-creation path derives from a
/// caller's explicit initial command and the workspace's remote startup command.
///
/// Both `newTerminalSplitLocal` and `newTerminalSurfaceLocal` computed this same
/// pair inline, byte-identically:
///
/// ```swift
/// let startupCommand = explicitInitialCommand ?? remoteTerminalStartupCommand
/// let remoteStartupCommandForEnvironment = explicitInitialCommand == nil ? remoteTerminalStartupCommand : nil
/// ```
///
/// The two values encode one rule: an explicit command, when present, fully
/// replaces the remote command (so the remote command is then NOT folded into
/// the startup environment), and only the remote command contributes to the
/// startup environment overlay. ``SurfaceCreationCoordinator/resolveStartupCommand(explicitCommand:remoteCommand:)``
/// computes both from the already-normalized inputs so the two creation bodies
/// share one source of truth.
public struct TerminalStartupCommandResolution: Sendable, Equatable {
    /// The command the new surface launches: the explicit command when present,
    /// otherwise the remote startup command (either may be `nil`).
    public let startupCommand: String?

    /// The remote startup command to fold into the startup environment, which is
    /// the remote command only when no explicit command overrode it (`nil`
    /// otherwise, matching the legacy `explicitInitialCommand == nil ? … : nil`).
    public let remoteCommandForEnvironment: String?

    /// Creates a resolution from its two derived values.
    public init(startupCommand: String?, remoteCommandForEnvironment: String?) {
        self.startupCommand = startupCommand
        self.remoteCommandForEnvironment = remoteCommandForEnvironment
    }
}

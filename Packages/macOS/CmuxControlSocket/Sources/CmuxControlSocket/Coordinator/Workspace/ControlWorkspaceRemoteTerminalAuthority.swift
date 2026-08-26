public import Foundation

/// Authenticated authority for a terminal readiness report.
public enum ControlWorkspaceRemoteTerminalAuthority: Sendable, Equatable {
    /// A non-persistent relay identified by its port and terminal process generation.
    case relayPort(Int, terminalLifecycleID: UUID)
    /// A persistent PTY authenticated by broker ownership and terminal process generation.
    case persistentTransport(String, terminalLifecycleID: UUID)
}

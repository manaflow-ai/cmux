public import Foundation

/// Authenticated authority for a terminal readiness report.
public enum ControlWorkspaceRemoteTerminalAuthority: Sendable, Equatable {
    /// A non-persistent relay identified by its port and terminal process generation.
    case relayPort(Int, terminalLifecycleID: UUID)
    /// A persistent PTY generation authenticated by its broker transport.
    case persistentTransport(String)
}

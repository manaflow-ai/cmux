/// Authenticated authority for a terminal readiness report.
public enum ControlWorkspaceRemoteTerminalAuthority: Sendable, Equatable {
    /// A non-persistent relay generation identified by its listening port.
    case relayPort(Int)
    /// A persistent PTY generation authenticated by its broker transport.
    case persistentTransport(String)
}

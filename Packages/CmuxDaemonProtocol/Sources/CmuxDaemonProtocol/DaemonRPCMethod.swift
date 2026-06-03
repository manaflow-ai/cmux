public import Foundation

/// The canonical `cmuxd-remote` JSON-RPC method names.
///
/// The daemon dispatches each request on its `method` field. Centralizing the
/// wire strings here keeps the client and any future caller in agreement on the
/// exact names the daemon recognizes, instead of scattering string literals
/// across the transport code.
public enum DaemonRPCMethod {
    /// The initial handshake that returns a ``TerminalRemoteDaemonHello``.
    public static let hello = "hello"
    /// Opens (or re-opens) a session, returning a ``TerminalRemoteDaemonSessionStatus``.
    public static let sessionOpen = "session.open"
    /// Attaches a client to an existing session.
    public static let sessionAttach = "session.attach"
    /// Resizes a session's attachment grid.
    public static let sessionResize = "session.resize"
    /// Detaches a client from a session.
    public static let sessionDetach = "session.detach"
    /// Closes a session entirely.
    public static let sessionClose = "session.close"
    /// Lists active sessions, returning a ``TerminalRemoteDaemonSessionListResult``.
    public static let sessionList = "session.list"
    /// Fetches a session's scrollback, returning a ``TerminalRemoteDaemonSessionHistoryResult``.
    public static let sessionHistory = "session.history"
    /// Opens a PTY-backed terminal, returning a ``TerminalRemoteDaemonTerminalOpenResult``.
    public static let terminalOpen = "terminal.open"
    /// Reads a window of terminal output, returning a ``TerminalRemoteDaemonTerminalReadResult``.
    public static let terminalRead = "terminal.read"
    /// Writes input bytes to a terminal session.
    public static let terminalWrite = "terminal.write"
    /// Subscribes to push output for a session, returning the initial ``TerminalRemoteDaemonTerminalReadResult``.
    public static let terminalSubscribe = "terminal.subscribe"
    /// Lists workspaces, returning a ``TerminalRemoteDaemonWorkspaceListResult``.
    public static let workspaceList = "workspace.list"
    /// Subscribes to workspace changes, returning the initial ``TerminalRemoteDaemonWorkspaceListResult``.
    public static let workspaceSubscribe = "workspace.subscribe"
    /// Creates a workspace, returning a ``TerminalRemoteDaemonWorkspaceCreateResult``.
    public static let workspaceCreate = "workspace.create"
    /// Opens a new pane (and shell session) in a workspace, returning a ``TerminalRemoteDaemonWorkspaceOpenPaneResult``.
    public static let workspaceOpenPane = "workspace.open_pane"
    /// Renames a workspace.
    public static let workspaceRename = "workspace.rename"
    /// Pins or unpins a workspace.
    public static let workspacePin = "workspace.pin"
    /// Configures the daemon-side APNs forwarder.
    public static let daemonConfigureNotifications = "daemon.configure_notifications"
}

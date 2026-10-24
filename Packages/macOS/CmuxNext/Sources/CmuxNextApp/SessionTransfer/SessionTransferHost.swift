import CmuxNextDaemon

/// What session transfer needs from the app that hosts it, as plain values.
///
/// ``SessionTransferService`` reads the daemon, opens workspaces and asks about agent chats
/// only through this protocol, so it names no window, workspace-spawn or agent pane type.
/// The app's composition root passes ``AppSessionTransferHost``; a test passes a fake.
///
/// The app may go away while a transfer runs: then every optional member answers nil and
/// every throwing method throws ``SessionTransferService/Failure/unavailable``.
@MainActor
protocol SessionTransferHost {
    /// This build's own control socket, which peer discovery skips.
    var ownSocketPath: String? { get }
    /// The local daemon's connection, nil while it is not connected.
    var daemonConnection: DaemonConnection? { get }
    /// The local daemon's store, which mirrors its workspaces.
    var daemonStore: DaemonStore? { get }
    /// This build's acpmux, nil when the app runs without one (a mock agent host, no binary).
    var acpmux: SessionTransferAcpmux? { get }
    /// Whether a pane of the local daemon can get a new agent chat tab now.
    var canHostChats: Bool? { get }

    /// Opens a new workspace in the active window whose first tab resumes `harness`'s
    /// session `sessionID`, and returns the workspace id. The workspace may fall back to a
    /// terminal when no agent can be hosted yet.
    func createAgentWorkspace(cwd: String?, name: String?, harness: String, sessionID: String) async throws -> String
    /// Opens a new workspace in the active window with one terminal in `cwd` running
    /// `command` (a shell when nil), and returns the workspace id.
    func createTerminalWorkspace(cwd: String?, name: String?, command: String?) async throws -> String
    /// Opens a new workspace in the active window showing acpmux session `session` of this
    /// build, and returns the workspace id.
    func createChatWorkspace(name: String?, session: String) async throws -> String
    /// The agent tab key that shows acpmux session `session` of this Mac, if any.
    func agentTab(showing session: String) -> String?
    /// This build's chats another build can take, by tab id: chats of this Mac's acpmux (not
    /// the Chief home's, not another machine's) that have a session.
    func localChats() -> [String: (session: String, harness: String?)]
    /// Starts this Mac's local agent session host, if it is not running.
    func prewarmLocalChatHost() async throws
}

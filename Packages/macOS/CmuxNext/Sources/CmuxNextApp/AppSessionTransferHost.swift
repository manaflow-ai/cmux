import CmuxNextAgentPane
import CmuxNextDaemon

/// Session transfer's view of the app: forwards to the daemon, the windows and the agent tabs.
///
/// Built at the composition root, so the app's object graph keeps its own surface and the
/// transfer code names no window, workspace-spawn or agent pane type. It holds the app
/// weakly (the app owns the service that owns this) and reads each part when asked, as the
/// service did before; once the app is gone it answers nil and throws
/// ``SessionTransferService/Failure/unavailable``.
@MainActor
final class AppSessionTransferHost: SessionTransferHost {
    private weak var services: AppServices?

    init(services: AppServices) { self.services = services }

    var ownSocketPath: String? { services?.environment.launch.socketPath }
    var daemonConnection: DaemonConnection? { services?.daemon.connection }
    var daemonStore: DaemonStore? { services?.daemon.store }
    var acpmux: SessionTransferAcpmux? { services.flatMap(QuitAgents.environment).map(SessionTransferAcpmux.init) }
    var canHostChats: Bool? { services.map { $0.agentTabs.canHost(on: $0.daemon) } }

    func createAgentWorkspace(cwd: String?, name: String?, harness: String, sessionID: String) async throws -> String {
        var spawn = WorkspaceSpawn(cwd: cwd, name: name)
        spawn.firstChat = AgentPaneSeed(cwd: cwd, adopt: AgentPaneAdopt(harness: harness, agentSessionId: sessionID))
        return try await createWorkspace(spawn)
    }

    func createTerminalWorkspace(cwd: String?, name: String?, command: String?) async throws -> String {
        try await createWorkspace(WorkspaceSpawn(cwd: cwd, name: name, command: command))
    }

    func createChatWorkspace(name: String?, session: String) async throws -> String {
        var spawn = WorkspaceSpawn(name: name)
        spawn.firstSession = session
        return try await createWorkspace(spawn)
    }

    func agentTab(showing session: String) -> String? { services?.agentTabs.tab(showing: session) }

    func localChats() -> [String: (session: String, harness: String?)] {
        guard let tabs = services?.agentTabs, let localHost = tabs.localHost else { return [:] }
        var chats: [String: (session: String, harness: String?)] = [:]
        for (key, record) in tabs.listTabs() where record.host == localHost {
            if let session = tabs.session(of: key) { chats[key] = (session, record.harness) }
        }
        return chats
    }

    func prewarmLocalChatHost() async throws {
        guard let tabs = services?.agentTabs else { throw SessionTransferService.Failure.unavailable }
        try await (tabs.localSessionHost ?? tabs.host).prewarm()
    }

    /// Opens `spawn` in the active window, else the registry's pick.
    private func createWorkspace(_ spawn: WorkspaceSpawn) async throws -> String {
        guard let windows = services?.windows else { throw SessionTransferService.Failure.unavailable }
        return try await windows.createWorkspace(spawn, into: windows.targetWindow(preferring: windows.active?.state.id))
    }
}

private extension SessionTransferAcpmux {
    init(_ environment: AcpmuxEnvironment) {
        self.init(executable: environment.executable, socketPath: environment.socketPath, home: environment.home,
                  childEnvironment: environment.childEnvironment)
    }
}

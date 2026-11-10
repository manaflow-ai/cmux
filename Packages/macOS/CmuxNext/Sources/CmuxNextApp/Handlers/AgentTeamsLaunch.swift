import CmuxNextActions
import CmuxNextDaemon
import CmuxNextWindowRules

/// Launch Claude Teams and Launch Codex Teams: one path behind the palette, the CLI
/// (`cmux agent launch-claude-teams|launch-codex-teams`) and MCP `action run`.
///
/// Each opens a new terminal tab in the focused pane (in the focused terminal's folder), or a new
/// workspace when no pane is focused, and starts the agent there with its team mode on. Classic
/// `cmux claude-teams` also put each teammate in its own split through a private tmux shim, and
/// `cmux codex-teams` opened each subagent in a split through a Codex app-server watcher; cmux-next
/// has neither yet, so the teammates and subagents run inside the one terminal.
/// The action and the shell line of each are cmux-window-rules `chat::agent::tables` (`teams`).
enum AgentTeamsLaunch: CaseIterable {
    case claude, codex

    /// The launcher an action runs, or nil for any other action.
    init?(actionID: ActionID) {
        guard let launch = Self.allCases.first(where: { $0.actionID == actionID }) else { return nil }
        self = launch
    }

    private var harness: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }

    private var row: WindowRules.ChatAgentTables.TeamsLaunch? {
        WindowRules.chatAgentTables?.teams.first { $0.harness == harness }
    }

    /// The action that runs it; nil when the FFI does not answer (it is not bound).
    var actionID: ActionID? { row.map { ActionID(rawValue: $0.action) } }

    /// The line typed into the new terminal's shell.
    var shellLine: String? { row?.shellLine }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        for launch in allCases {
            guard let id = launch.actionID else { continue }
            registry.bind(id, run: { invocation in try launch.run(invocation, context: context) })
        }
    }

    private func run(_ invocation: ActionInvocation, context: AppActionContext) throws {
        let connection = try context.requireConnection()
        let scope = context.scope(invocation)
        guard let line = shellLine else { return }
        let logger = context.daemon.logger
        guard let pane = scope.pane else {
            let windows = context.services.windows
            let (key, rule) = NewWorkspacePlacements.placedCreate(in: windows) // no pane to open a tab in: a new workspace (cx-caoh)
            let repair = context.services.emptyWorkspaces
            let reveal = invocation.allowsViewChange
            Task {
                let surface: SurfaceID?
                do {
                    surface = try await WorkspaceCreation.create(key, name: nil, placedBy: rule, ledger: windows.newPlacements, on: connection, repair: repair) { created in
                        try await WorkspaceCreation.firstTerminal(in: created, cwd: nil, on: connection).surface
                    }
                } catch {
                    // The create ended without its workspace: drop the placement it left.
                    NewWorkspacePlacements.forget(key.rawValue, windows: windows)
                    logger.error("launch-agent-teams failed: \(String(describing: error), privacy: .public)")
                    return
                }
                do {
                    if let surface { try await connection.send(surface, text: line) }
                    if reveal { context.window(showing: key.rawValue) }
                } catch {
                    logger.error("launch-agent-teams failed: \(String(describing: error), privacy: .public)")
                }
            }
            return
        }
        let cwd = scope.tab.flatMap { $0.pane.tab($0.id) }?.cwd
        let options = SpawnOptions(cwd: cwd, workspace: context.services.workspaceKey(of: pane.pane))
        let handle = pane.pane.handle
        Task {
            do {
                let surface = try await connection.newTab(in: handle, options: options).surface
                try await connection.send(surface, text: line)
            } catch {
                logger.error("launch-agent-teams failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

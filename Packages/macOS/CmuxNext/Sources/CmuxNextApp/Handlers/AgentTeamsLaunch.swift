import CmuxNextActions
import CmuxNextDaemon

/// Launch Claude Teams and Launch Codex Teams: one path behind the palette, the CLI
/// (`cmux agent launch-claude-teams|launch-codex-teams`) and MCP `action run`.
///
/// Each opens a new terminal tab in the focused pane (in the focused terminal's folder), or a new
/// workspace when no pane is focused, and starts the agent there with its team mode on. Classic
/// `cmux claude-teams` also put each teammate in its own split through a private tmux shim, and
/// `cmux codex-teams` opened each subagent in a split through a Codex app-server watcher; cmux-next
/// has neither yet, so the teammates and subagents run inside the one terminal.
enum AgentTeamsLaunch: CaseIterable {
    case claude, codex

    /// The launcher an action runs, or nil for any other action.
    init?(actionID: ActionID) {
        guard let launch = Self.allCases.first(where: { $0.actionID == actionID }) else { return nil }
        self = launch
    }

    var actionID: ActionID {
        switch self {
        case .claude: "palette.launchClaudeTeams"
        case .codex: "palette.launchCodexTeams"
        }
    }

    /// The line typed into the new terminal's shell. The environment assignment applies to the
    /// agent only, so the shell keeps its own environment after the agent exits.
    var shellLine: String {
        switch self {
        case .claude: "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --teammate-mode in-process\n"
        case .codex: "codex -c features.multi_agent=true\n"
        }
    }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        for launch in allCases {
            registry.bind(launch.actionID, run: { invocation in try launch.run(invocation, context: context) })
        }
    }

    private func run(_ invocation: ActionInvocation, context: AppActionContext) throws {
        let connection = try context.requireConnection()
        let scope = context.scope(invocation)
        let line = shellLine
        let logger = context.daemon.logger
        guard let pane = scope.pane else {
            // No pane to open a tab in: a new workspace, placed like Cmd-N (cx-caoh).
            let key = WorkspaceKey.generate()
            let windows = context.services.windows
            NewWorkspacePlacements.expect(key.rawValue, in: nil, byDefault: NewWorkspacePlacements.rule(for: nil, in: windows), windows: windows)
            let repair = context.services.emptyWorkspaces
            let reveal = invocation.allowsViewChange
            Task {
                do {
                    let surface = try await WorkspaceCreation.create(key, name: nil, on: connection, repair: repair) { created in
                        try await WorkspaceCreation.firstTerminal(in: created, cwd: nil, on: connection).surface
                    }
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

import AppKit
import CmuxNextActions
import CmuxNextDaemon

/// Agent actions. Forks read the agent session the daemon reports for the
/// focused terminal (`TabModel.agent`, from `list-agents` state) and start
/// `claude --resume <session> --fork-session` in a new terminal placed by
/// daemon commands. Chat, Teams, and Computer Use are typed-unavailable.
enum AgentHandlers {
    enum Placement {
        case right, left, above, below, newTab, newWorkspace
    }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let forks: [(ActionID, Placement)] = [
            ("palette.forkAgentConversationRight", .right), ("palette.forkAgentConversationLeft", .left),
            ("palette.forkAgentConversationTop", .above), ("palette.forkAgentConversationBottom", .below),
            ("palette.forkAgentConversationNewTab", .newTab), ("palette.forkAgentConversationNewWorkspace", .newWorkspace),
        ]
        for (id, placement) in forks {
            registry.bind(id, run: { try fork(placement, invocation: $0, context: context) })
        }
        registry.bind("palette.computerUse.accessibility", run: { _ in try openPrivacyPane("Privacy_Accessibility", context) })
        registry.bind("palette.computerUse.screenRecording", run: { _ in try openPrivacyPane("Privacy_ScreenCapture", context) })
        registry.bindUnavailable(["palette.newAgentChat", "palette.openTerminalChatView"], ActionFailure(message: HandlerStrings.agentChat))
        registry.bindUnavailable(["palette.launchClaudeTeams", "palette.launchCodexTeams"], ActionFailure(message: HandlerStrings.agentTeams))
        registry.bindUnavailable(
            ["palette.computerUse.setup", "computerUseFocus", "computerUseFocusCallingTerminal", "computerUseStop"],
            ActionFailure(message: HandlerStrings.computerUse)
        )
    }

    /// The shell line that forks `session`, or nil for agents without fork
    /// support or session ids that are not plain tokens.
    static func forkCommand(agent: String?, session: String?) -> String? {
        guard agent?.lowercased().contains("claude") == true, let session, !session.isEmpty,
              session.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return "claude --resume \(session) --fork-session"
    }

    private static func fork(_ placement: Placement, invocation: ActionInvocation, context: AppActionContext) throws {
        guard let (pane, id) = context.scope(invocation).tab, let tab = pane.tab(id), tab.kind == .pty else {
            throw ActionFailure(message: HandlerStrings.noTerminal)
        }
        guard let status = tab.agent, status.session?.isEmpty == false else { throw ActionFailure(message: HandlerStrings.noAgentSession) }
        guard let command = forkCommand(agent: status.agent, session: status.session) else {
            throw ActionFailure(message: HandlerStrings.forkClaudeOnly)
        }
        let connection = try context.connection()
        let handle = pane.pane.handle
        let options = SpawnOptions(cwd: tab.cwd)
        let line = command + "\n"
        let logger = context.daemon.logger
        Task {
            do {
                let surface: SurfaceID?
                var workspace: WorkspaceKey?
                switch placement {
                case .right, .left:
                    surface = try await connection.split(handle, direction: .right, options: options).surface
                    // A split always opens right/below; swap to put the fork first.
                    if placement == .left { try await connection.swapPane(handle, with: .direction(.right)) }
                case .below, .above:
                    surface = try await connection.split(handle, direction: .down, options: options).surface
                    if placement == .above { try await connection.swapPane(handle, with: .direction(.down)) }
                case .newTab:
                    surface = try await connection.newTab(in: handle, options: options).surface
                case .newWorkspace:
                    let created = try await connection.createWorkspace()
                    workspace = created.key
                    surface = try await connection.createTerminal(in: created.key, cwd: options.cwd).surface
                }
                if let surface { try await connection.send(surface, text: line) }
                if let workspace { context.window(showing: workspace.rawValue) }
            } catch {
                logger.error("fork-agent-conversation failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func openPrivacyPane(_ anchor: String, _ context: AppActionContext) throws {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        try context.open(url)
    }
}

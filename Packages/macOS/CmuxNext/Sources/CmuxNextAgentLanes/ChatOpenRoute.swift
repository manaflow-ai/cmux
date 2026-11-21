public import CmuxNextAgentPane
import CmuxNextHistory

/// What Open Chat does with a daemon plan (Lawrence 2026-10-09): one click on a chat shows it in a
/// NEW WORKSPACE as the ACP agent pane, focus moving there, never a terminal; a chat a tab already
/// resumes shows that tab instead of a duplicate. A chat acpmux cannot resume over ACP yet opens a
/// fresh agent chat in its folder on its harness. A terminal only from Open in Terminal (`inTerminal`).
/// Pure, so the decision is tested without windows.
public enum ChatOpenRoute: Equatable {
    /// The tab (`TabModel.id`) that already resumes this chat.
    case reveal(tab: String)
    /// A new workspace named `name`: its first tab is the agent chat `seed`, or (Open in Terminal)
    /// a terminal that runs `command` with `env`.
    case newWorkspace(name: String?, cwd: String?, seed: AgentPaneSeed?, command: String?, env: [String: String])
    case readOnly(path: String)
    case needsFolder(reason: String)

    /// `watch`: View Only, for a chat acpmux would adopt (Claude Code, Codex): the tab shows it
    /// without running it. Any other plan or harness opens as it would.
    public static func route(_ plan: AcpmuxChatOpenPlan, chat: ChatOpenSubject, inTerminal: Bool = false, watch: Bool = false, reveal: String? = nil,
                             openTab: (AgentPaneAdopt) -> String?) -> ChatOpenRoute {
        if inTerminal { return terminal(plan, chat: chat) }
        switch plan.action {
        case .needsFolder(let reason): return .needsFolder(reason: reason)
        case .adopt(var adopt, let cwd, _):
            // Only Claude Code and Codex chats are watched; a daemon without `family` names the
            // profile after its family.
            if watch, ["claude", "codex"].contains(plan.family ?? adopt.harness) { adopt.watch = true }
            return openTab(adopt).map { .reveal(tab: $0) }
                ?? .newWorkspace(name: chat.title, cwd: cwd, seed: AgentPaneSeed(cwd: cwd, adopt: adopt, pastChat: chat.key, revealTurn: reveal),
                                 command: nil, env: [:])
        case .terminal(_, _, let cwd):
            return .newWorkspace(name: chat.title, cwd: cwd ?? chat.cwd,
                                 seed: AgentPaneSeed(cwd: cwd ?? chat.cwd, harness: chat.acpHarness, pastChat: chat.key), command: nil, env: [:])
        case .readOnly:
            return .newWorkspace(name: chat.title, cwd: chat.cwd,
                                 seed: AgentPaneSeed(cwd: chat.cwd, harness: chat.acpHarness, pastChat: chat.key), command: nil, env: [:])
        }
    }

    /// Open in Terminal (the row's menu): the harness's own resume command in a new workspace.
    private static func terminal(_ plan: AcpmuxChatOpenPlan, chat: ChatOpenSubject) -> ChatOpenRoute {
        switch plan.action {
        case .needsFolder(let reason): return .needsFolder(reason: reason)
        case .terminal(let argv, let env, let cwd):
            return .newWorkspace(name: chat.title, cwd: cwd, seed: nil, command: argv.map(AgentResume.shellQuoted).joined(separator: " "), env: env)
        case .adopt(let adopt, let cwd, _):
            let command = AgentResume.command(provider: chat.harness ?? adopt.harness, sessionID: adopt.agentSessionId)
            return .newWorkspace(name: chat.title, cwd: cwd, seed: nil, command: command, env: [:])
        case .readOnly(let path): return .readOnly(path: path)
        }
    }
}

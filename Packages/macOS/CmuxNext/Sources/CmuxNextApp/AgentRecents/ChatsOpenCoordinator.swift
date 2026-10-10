import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextHistory
import Foundation

/// The chat as Open Chat names it (the index's metadata).
struct ChatOpenSubject: Equatable {
    var title: String?
    /// The index harness id (`claude-code`, `codex`, `opencode`, `pi`, ...).
    var harness: String?
    var sessionID: String?
    var cwd: String?

    /// The acpmux harness family a fresh agent chat for this chat starts on, nil for the default.
    var acpHarness: String? {
        switch harness {
        case "claude-code": "claude"
        case "codex", "opencode", "gemini", "pi": harness
        case "cursor-agent": "cursor"
        default: nil
        }
    }
}

/// What Open Chat does with a daemon plan (Lawrence 2026-10-09): one click on a chat shows it in a
/// NEW WORKSPACE as the ACP agent pane, focus moving there, never a terminal; a chat a tab already
/// resumes shows that tab instead of a duplicate. A chat acpmux cannot resume over ACP yet opens a
/// fresh agent chat in its folder on its harness. A terminal only from Open in Terminal (`inTerminal`).
/// Pure, so the decision is tested without windows.
enum ChatOpenRoute: Equatable {
    /// The tab (`TabModel.id`) that already resumes this chat.
    case reveal(tab: String)
    /// A new workspace named `name`: its first tab is the agent chat `seed`, or (Open in Terminal)
    /// a terminal that runs `command` with `env`.
    case newWorkspace(name: String?, cwd: String?, seed: AgentPaneSeed?, command: String?, env: [String: String])
    case readOnly(path: String)
    case needsFolder(reason: String)

    static func route(_ plan: AcpmuxChatOpenPlan, chat: ChatOpenSubject, inTerminal: Bool = false,
                      openTab: (AgentPaneAdopt) -> String?) -> ChatOpenRoute {
        if inTerminal { return terminal(plan, chat: chat) }
        switch plan.action {
        case .needsFolder(let reason): return .needsFolder(reason: reason)
        case .adopt(let adopt, let cwd, _):
            return openTab(adopt).map { .reveal(tab: $0) }
                ?? .newWorkspace(name: chat.title, cwd: cwd, seed: AgentPaneSeed(cwd: cwd, adopt: adopt), command: nil, env: [:])
        case .terminal(_, _, let cwd):
            return .newWorkspace(name: chat.title, cwd: cwd ?? chat.cwd, seed: AgentPaneSeed(cwd: cwd ?? chat.cwd, harness: chat.acpHarness),
                                 command: nil, env: [:])
        case .readOnly:
            return .newWorkspace(name: chat.title, cwd: chat.cwd, seed: AgentPaneSeed(cwd: chat.cwd, harness: chat.acpHarness),
                                 command: nil, env: [:])
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

/// The one user-initiated Open Chat path shared by the sidebar's All chats, the palette and the
/// New Tab cards.
@MainActor
final class ChatsOpenCoordinator {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
        // Choose Folder… in a pane whose chat has no folder (cx-nn3e.1): that pane's folder
        // sheet, then `chat_open` again with the pick.
        AgentPaneModel.chatFolderChooser = { [weak self] model, chat in
            guard let self, let view = self.services?.agentTabs.views.values.first(where: { $0.model === model }),
                  let url = await view.pickFolder() else { return .cancelled }
            return await self.reopen(chat, in: url.path)
        }
    }

    /// Open in Terminal (the row's right-click menu): the harness's own resume command.
    func openInTerminal(_ key: String) { open(key, inTerminal: true) }

    func open(_ key: String, inTerminal: Bool = false) {
        let timing = ChatOpenTiming(key: key)
        guard let services, let environment = QuitAgents.environment(services) else { return timing.end("no_environment") }
        Task { [weak self] in
            guard let self else { return timing.end("released") }
            do {
                guard let plan = try await environment.chatOpenPlan(key: key) else { return timing.end("no_plan") }
                timing.mark("plan")
                await dispatch(plan, key: key, environment: environment, inTerminal: inTerminal, timing: timing)
            } catch {
                timing.end("plan_failed")
                services.refusalHUD.show(error.localizedDescription, in: services.windows.active?.window ?? NSApp.keyWindow)
            }
        }
    }

    private func dispatch(_ plan: AcpmuxChatOpenPlan, key: String, environment: AcpmuxEnvironment, inTerminal: Bool = false,
                          timing: ChatOpenTiming? = nil) async {
        guard let services else { timing?.end("released"); return }
        let chat = services.chatsFeed?.chats.first { $0.id == key }
        let title = chat?.title
        let subject = ChatOpenSubject(title: title, harness: chat?.harness, sessionID: chat?.sessionID, cwd: chat?.cwd)
        switch ChatOpenRoute.route(plan, chat: subject, inTerminal: inTerminal, openTab: { services.agentTabs.tab(resuming: $0) }) {
        case .needsFolder(let reason):
            // The chat opens (in its new workspace) and says why it has no folder, with Choose
            // Folder there (cx-nn3e.1), never a bare Open panel.
            createWorkspace(WorkspaceSpawn(name: title), seed: AgentPaneSeed(folderNeeded: AgentPaneFolderNeeded(chat: key, reason: reason)),
                            timing: timing, route: "needs_folder")
        case .reveal(let tab):
            let shown = services.revealTab(tab)
            timing?.end(shown ? "reveal" : "reveal_failed")
        case .newWorkspace(let name, let cwd, let seed, let command, let env):
            createWorkspace(WorkspaceSpawn(cwd: cwd, name: name, command: command, env: env), seed: seed,
                            timing: timing, route: seed == nil ? "terminal" : "workspace")
        case .readOnly(let path):
            guard let pane = services.windows.active?.focusedPane else { timing?.end("read_only_no_pane"); return }
            _ = services.viewers.markdownPages.open(URL(fileURLWithPath: path), in: pane, focus: true, userChose: false)
            timing?.end("read_only")
        }
    }

    /// A new workspace in the active window whose first tab is `seed`'s chat (or `spawn`'s
    /// command); it shows there and takes focus.
    private func createWorkspace(_ spawn: WorkspaceSpawn, seed: AgentPaneSeed?, timing: ChatOpenTiming? = nil, route: String = "workspace") {
        guard let services else { timing?.end("released"); return }
        var spawn = spawn
        spawn.firstChat = seed
        let windowID = services.windows.active?.state.id
        services.registry.track(Task { @MainActor in
            do {
                _ = try await services.windows.createWorkspace(spawn, into: windowID)
                timing?.end(route)
                return nil
            } catch {
                timing?.end("workspace_failed")
                return ActionWorkFailure("open chat", error)
            }
        })
    }

    /// Choose Folder… in the pane of a chat whose folder is missing: acpmux's `chat_open` again
    /// with the pick. A resumable chat resumes in that pane; another kind opens as Open Chat
    /// opens it; a pick that still does not work keeps the pane's line with acpmux's reason.
    func reopen(_ key: String, in folder: String) async -> AgentPaneChatFolderResult {
        guard let services, let environment = QuitAgents.environment(services) else { return .needsFolder(RefusalStrings.agentTabCreateFailed) }
        do {
            guard let plan = try await environment.chatOpenPlan(key: key, cwd: folder) else { return .needsFolder(RefusalStrings.agentTabCreateFailed) }
            switch plan.action {
            case .adopt(let adopt, let cwd, _): return .adopt(adopt, cwd: cwd ?? folder)
            case .needsFolder(let reason): return .needsFolder(reason)
            case .terminal, .readOnly:
                await dispatch(plan, key: key, environment: environment)
                return .opened
            }
        } catch {
            return .needsFolder(error.localizedDescription)
        }
    }
}

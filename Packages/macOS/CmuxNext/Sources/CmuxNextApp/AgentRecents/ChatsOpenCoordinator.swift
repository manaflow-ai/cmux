import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextHistory
import Foundation

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

    /// `watch`: View Only, for a chat acpmux would adopt (Claude Code, Codex): the tab shows it
    /// without running it. Any other plan or harness opens as it would.
    static func route(_ plan: AcpmuxChatOpenPlan, chat: ChatOpenSubject, inTerminal: Bool = false, watch: Bool = false,
                      openTab: (AgentPaneAdopt) -> String?) -> ChatOpenRoute {
        if inTerminal { return terminal(plan, chat: chat) }
        switch plan.action {
        case .needsFolder(let reason): return .needsFolder(reason: reason)
        case .adopt(var adopt, let cwd, _):
            // Only Claude Code and Codex chats are watched; a daemon without `family` names the
            // profile after its family.
            if watch, ["claude", "codex"].contains(plan.family ?? adopt.harness) { adopt.watch = true }
            return openTab(adopt).map { .reveal(tab: $0) }
                ?? .newWorkspace(name: chat.title, cwd: cwd, seed: AgentPaneSeed(cwd: cwd, adopt: adopt, pastChat: chat.key),
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
        // A fresh chat opened for a chat that cannot resume here shows its past (cx-khns1).
        AgentPanePastTurn.reader = { [weak self] chat in
            guard let services = self?.services, let environment = QuitAgents.environment(services) else { return [] }
            return (try? await environment.chatTranscript(key: chat)) ?? []
        }
    }

    /// Open in Terminal (the row's right-click menu): the harness's own resume command.
    func openInTerminal(_ key: String) { open(key, inTerminal: true) }

    /// `page`: the New Tab page the row was clicked on; the chat replaces it in its tab. `watch`: View
    /// Only (an All chats row's menu, `agentChat.view`, `cmux agent view`): a tab that shows the chat
    /// and follows the app that runs it, without running it, until Take Over.
    func open(_ key: String, inTerminal: Bool = false, watch: Bool = false, replacing page: String? = nil) {
        guard let services, let environment = QuitAgents.environment(services) else { return }
        // A chat a tab already shows (its agent chat, else the terminal running it) is shown there,
        // never opened again in a new workspace that then asks to Fork or Open Anyway. Open in
        // Terminal and an explicit View Only still open their own tab.
        if !inTerminal, !watch, revealRunning(key) { return }
        // Every Open of an outside Claude Code or Codex chat is View Only unless the Debug toggle is off.
        let watch = watch || AgentPaneTunables.openOutsideChatsViewOnly.value
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let plan = try await environment.chatOpenPlan(key: key) else { return }
                await dispatch(plan, key: key, environment: environment, inTerminal: inTerminal, watch: watch, replacing: page)
            } catch {
                services.refusalHUD.show(error.localizedDescription, in: services.windows.active?.window ?? services.keyWindowSource())
            }
        }
    }

    /// Shows the tab that already shows chat `key`: the agent chat resuming it, else a live
    /// terminal running it (the lookup `cmux://agent` links use). False when no tab shows it.
    private func revealRunning(_ key: String) -> Bool {
        guard let services else { return false }
        let chat = services.chatsFeed?.chat(id: key)
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        // The index names Claude Code `claude-code`; tabs and terminals name it `claude`.
        guard let harness = TerminalChatRoute.harness(of: chat?.harness ?? parts.first),
              let session = chat?.sessionID ?? (parts.count == 2 ? parts[1] : nil) else { return false }
        return services.revealAgentSession(harness: harness, session: session)
    }

    private func dispatch(_ plan: AcpmuxChatOpenPlan, key: String, environment: AcpmuxEnvironment, inTerminal: Bool = false,
                          watch: Bool = false, replacing page: String? = nil) async {
        guard let services else { return }
        let chat = services.chatsFeed?.chat(id: key)
        let title = chat?.title
        // A chat past the feed's window (the New Tab list pages the whole index) still names its
        // harness and session id in its key (`harness:sessionId`).
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        let subject = ChatOpenSubject(title: title, harness: chat?.harness ?? parts.first,
                                      sessionID: chat?.sessionID ?? (parts.count == 2 ? parts[1] : nil), cwd: chat?.cwd, key: key)
        switch ChatOpenRoute.route(plan, chat: subject, inTerminal: inTerminal, watch: watch,
                                   openTab: { services.agentTabs.tab(resuming: $0) }) {
        case .needsFolder(let reason):
            // The chat opens (in its new workspace) and says why it has no folder, with Choose
            // Folder there (cx-nn3e.1), never a bare Open panel.
            let seed = AgentPaneSeed(folderNeeded: AgentPaneFolderNeeded(chat: key, reason: reason), pastChat: key)
            if let page, replace(page, with: seed) { return }
            createWorkspace(WorkspaceSpawn(name: title), seed: seed)
        case .reveal(let tab):
            _ = services.revealTab(tab)
        case .newWorkspace(let name, let cwd, let seed, let command, let env):
            if command == nil, let page, let seed, replace(page, with: seed) { return }
            createWorkspace(WorkspaceSpawn(cwd: cwd, name: name, command: command, env: env), seed: seed)
        case .readOnly(let path):
            guard let pane = services.windows.active?.focusedPane else { return }
            _ = services.viewers.markdownPages.open(URL(fileURLWithPath: path), in: pane, focus: true, userChose: false, readOnly: true)
        }
    }

    /// The New Tab page `page` opens `seed`'s chat in its place (opted in, beside it: NewTabPage.opensBeside);
    /// the page closes once the chat's tab exists. False when the page is gone.
    private func replace(_ page: String, with seed: AgentPaneSeed) -> Bool {
        guard let services else { return false }
        // The page's store id (it may have been provisional at the click). The New Tab page is an
        // agent tab, not an internal page tab: its pane is found by its tab model.
        let page = services.agentTabs.resolve(page)
        guard services.agentTabs.isNewTabPage(page), let (slot, model) = services.locateTab(page, onMachine: services.machines.local.machineID),
              let pane = services.paneController(for: model) else { return false }
        // A page of another machine never becomes a chat of this Mac (cx-k21v): the chat opens in a
        // new workspace of this Mac instead, as before open-here.
        guard pane.daemon.isLocal else { return false }
        if NewTabPage.opensBeside(page, in: pane, mainPane: false) {
            let closePage = NewTabPage.closingPage(page, in: pane)
            return services.linkOpener.open(from: pane, mainPane: false) { [services] target, placed in
                services.agentTabs.openTab(in: target, seed: AgentPaneSeedSource(seed), select: placed == nil) { key in
                    if let placed, let surface = services.locateTab(key, onMachine: target.daemon.machineID)?.0.surface { placed(surface) }
                    closePage()
                }
            }
        }
        let placed = NewTabSlot.placing(after: slot, services: services) { [weak pane] (_: String) in
            pane?.close([StripTabID(page)])
        }
        NewTabSuccession.begin(replacing: page, in: model, services: services) // the chat takes the page's tab in place
        return services.agentTabs.openTab(in: pane, seed: AgentPaneSeedSource(seed), then: placed)
    }

    /// A new workspace in the active window whose first tab is `seed`'s chat (or `spawn`'s
    /// command); it shows there and takes focus.
    private func createWorkspace(_ spawn: WorkspaceSpawn, seed: AgentPaneSeed?) {
        guard let services else { return }
        var spawn = spawn
        spawn.firstChat = seed
        let windowID = services.windows.active?.state.id
        services.registry.track(Task { @MainActor in
            do {
                _ = try await services.windows.createWorkspace(spawn, into: windowID)
                return nil
            } catch {
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

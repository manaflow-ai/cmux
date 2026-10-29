import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextOnboarding
import Foundation

/// Opens a `DeepLink` for `link.open`, the one path every link takes (the
/// OS URL handler, the palette, `cmux link open`, MCP). It only navigates,
/// through the code a user's own jump runs: a tab through
/// `AppServices.revealTab`, a pane through `revealTab` on its selected tab,
/// a workspace through `windows.reveal(workspaceID:)` and
/// `WindowActivation`. It never runs a command, sends text or changes
/// state; the only things it creates are the agent tab for a session no tab
/// shows, as opening that session from history does, and a closed tab a tab
/// link names, reopened from Recently Closed under its own id
/// (``DurableTabLink``). An agent link (`agent/<harness>/<session>`) only
/// reveals a tab this app already shows that session in, then, when the user
/// opened it, gives that tab's input the keyboard.
@MainActor
struct DeepLinkNavigator {
    let services: AppServices

    /// Shows `link`'s target.
    ///
    /// - Parameters:
    ///   - link: The parsed link.
    ///   - background: Bring the target forward without taking the key
    ///     window (Cmd held, or a run this client's user did not start).
    ///   - asking: A session link no tab shows asks before it opens a new tab (any page or app
    ///     can open the link). False only for the person's own click on an Agent Activity row,
    ///     which names the session itself.
    /// - Throws: `ActionFailure` when the target is closed, deleted or on a
    ///   machine that is not connected, or (nightly pane and tab links)
    ///   when only its workspace could be shown.
    func open(_ link: DeepLink, background: Bool, asking: Bool = true) throws {
        let intent: WindowActivation.Intent = background ? .bringForward : .raise
        switch link.target {
        case .tab(let id):
            // Open: show it. Closed: reopen it by its id, with the same id, and show it
            // (DurableTabLink, plans/cmux-next/durable-links-DESIGN.md).
            if services.revealTab(id, intent: intent) { return }
            DurableTabLink.open(id, intent: intent, services: services)
        case .pane(let id):
            guard let pane = services.pane(id: id) else { throw Self.gone }
            try reveal(pane, intent)
        case .workspace(let id):
            let workspace = services.machines.allWorkspaces.map(\.0).first { $0.resourceID?.rawValue == id }
            guard let workspace else { throw Self.gone }
            try reveal(workspace: workspace.id, intent)
        case .session(let id, let turn):
            try openSession(id, turn: turn, intent, asking: asking)
        case .chiefSession(let home, let session):
            // Only this app's Chief home, only a tab that shows that session there; never a
            // new tab (the session runs in the Chief home's acpmux, not this Mac's).
            let host = "chief:" + home
            guard services.agentTabs.chiefHost == host, let shown = services.agentTabs.tab(showing: session, host: host),
                  services.revealTab(shown, intent: intent) else { throw Self.gone }
        case .agent(let harness, let session):
            try openAgent(harness: harness, session: session, message: link.message, intent)
        case .group(let id, let workspace):
            // The named workspace when this Mac shows it; else the group's record from cmux Cloud
            // (CloudGroupLink), whose first workspace open here is shown.
            if let workspace, let open = services.machines.allWorkspaces.map(\.0).first(where: { $0.resourceID?.rawValue == workspace }) {
                try reveal(workspace: open.id, intent)
                return
            }
            CloudGroupLink.open(id, workspace: workspace, intent: intent, services: services)
        case .legacyWorkspace(let key, let fallback):
            guard let workspace = legacyWorkspace(key, fallback: fallback) else { throw Self.gone }
            try reveal(workspace: workspace.id, intent)
        case .legacyPane(let key, _):
            try revealLegacyItem(in: key, fallback: nil, intent)
        case .legacySurface(let key, _, let fallbackWorkspace, _):
            try revealLegacyItem(in: key, fallback: fallbackWorkspace, intent)
        }
    }

    static var gone: ActionFailure { ActionFailure(message: RefusalStrings.linkTargetGone) }

    /// A pane opens on its selected tab; a pane with none shows its workspace.
    private func reveal(_ pane: PaneModel, _ intent: WindowActivation.Intent) throws {
        if let tab = selectedTab(of: pane), services.revealTab(tab, intent: intent) { return }
        guard let workspace = services.daemon(for: pane).store.workspace(containing: pane.handle) else { throw Self.gone }
        try reveal(workspace: workspace.id, intent)
    }

    /// The tab the pane shows: its controller's selection when a window
    /// shows it, else the daemon's default tab.
    private func selectedTab(of pane: PaneModel) -> String? {
        if let selected = services.paneController(for: pane)?.stripModel.selectedID { return selected.rawValue }
        guard !pane.tabs.isEmpty else { return nil }
        return pane.tabs[min(max(pane.defaultTabIndex, 0), pane.tabs.count - 1)].id
    }

    /// The palette workspace switcher's path: the window that lists the
    /// workspace shows it, and comes forward. Refused when no window could
    /// show it, never a silent success.
    private func reveal(workspace id: String, _ intent: WindowActivation.Intent) throws {
        guard let window = services.windows.reveal(workspaceID: id), let nsWindow = window.window else { throw Self.gone }
        services.showJumpWindow(nsWindow, intent)
    }

    /// Selects the tab that shows the session, else (after the person's Open, `SessionLinkGate`)
    /// opens it in a new agent tab in the focused pane. A session acpmux does not have is refused
    /// with no question. Then the page scrolls to the turn, a page not loaded yet once its row renders.
    private func openSession(_ id: String, turn: String?, _ intent: WindowActivation.Intent, asking: Bool) throws {
        let tabs = services.agentTabs
        let reveal = { @MainActor () -> Bool in
            guard let shown = tabs.tab(showing: id), services.revealTab(shown, intent: intent) else { return false }
            if let turn { tabs.revealTurn(turn, in: shown) }
            return true
        }
        if reveal() { return }
        guard let pane = services.windows.active?.focusedPane else { throw ActionFailure(message: MiscHandlerStrings.noPane) }
        // The store commits the tab first; the turn waits for its page. A pane that left its
        // window while the question was up opens nothing.
        let openNew: @MainActor () -> Bool = { [weak pane] in
            guard let pane, pane.view.window != nil else { return false }
            pane.openAgentSession(id) { key in if let turn { tabs.revealTurn(turn, in: key) } }
            return true
        }
        guard asking else { _ = openNew(); return }
        // The question, and a refusal, show in the window of the pane the tab would open in.
        let window = pane.view.window
        let hud = services.refusalHUD
        let outcome = services.sessionLinks.open(id, in: window, reveal: reveal, openNew: openNew)
        Task { if await outcome.value == .refused { hud.show(Self.gone.message, in: window) } }
    }

    /// An outside agent's session (hq#2555): only a tab already showing it (the chat that adopted
    /// it, else the terminal running it), never a new tab, resume or connection. A user's open
    /// raises it, so its composer or terminal has the keyboard. A link's `message=<id>` then
    /// scrolls that message's row into view and marks it, in the chat tab that shows the session;
    /// a message this machine's transcript does not have, or a terminal, leaves the view where it
    /// is (schemas/deeplinks/agent-link.json).
    private func openAgent(harness: String, session: String, message: String?,
                           _ intent: WindowActivation.Intent) throws {
        guard AgentPaneTunables.agentLinks.value else { throw ActionFailure(message: RefusalStrings.agentLinksOff) }
        guard let shown = services.revealedAgentSessionTab(harness: harness, session: session, intent: intent) else { throw Self.gone }
        if let message, shown.adopted {
            services.agentTabs.revealTurn(AgentTabStore.messageReveal(message), in: shown.tab)
        }
    }

    /// Nightly's durable workspace UUID is `WorkspaceModel.id` (the
    /// lowercase workspace key); the `stable_workspace_id` fallback is tried next.
    private func legacyWorkspace(_ key: UUID, fallback: UUID?) -> WorkspaceModel? {
        for candidate in [key, fallback].compactMap({ $0 }) {
            if let workspace = services.workspace(id: candidate.uuidString.lowercased()) { return workspace }
        }
        return nil
    }

    /// Nightly pane and surface UUIDs have no counterpart here: the
    /// workspace opens and the refusal says the item itself wasn't found.
    private func revealLegacyItem(in key: UUID, fallback: UUID?, _ intent: WindowActivation.Intent) throws {
        guard let workspace = legacyWorkspace(key, fallback: fallback) else { throw Self.gone }
        try reveal(workspace: workspace.id, intent)
        throw ActionFailure(message: RefusalStrings.linkItemNotFound)
    }
}

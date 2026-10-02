import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDesign
import Foundation

/// Opens a `DeepLink` for `link.open`, the one path every link takes (the
/// OS URL handler, the palette, `cmux link open`, MCP). It only navigates,
/// through the code a user's own jump runs: a tab through
/// `AppServices.revealTab`, a pane through `revealTab` on its selected tab,
/// a workspace through `windows.reveal(workspaceID:)` and
/// `WindowActivation`. It never runs a command, sends text or changes
/// state; the only thing it creates is the agent tab for a session no tab
/// shows, as opening that session from history does.
@MainActor
struct DeepLinkNavigator {
    let services: AppServices

    /// Shows `link`'s target.
    ///
    /// - Parameters:
    ///   - link: The parsed link.
    ///   - background: Bring the target forward without taking the key
    ///     window (Cmd held, or a run this client's user did not start).
    /// - Throws: `ActionFailure` when the target is closed, deleted or on a
    ///   machine that is not connected, or (nightly pane and tab links)
    ///   when only its workspace could be shown.
    func open(_ link: DeepLink, background: Bool) throws {
        let intent: WindowActivation.Intent = background ? .bringForward : .raise
        switch link.target {
        case .tab(let id):
            guard services.revealTab(id, intent: intent) else { throw Self.gone }
        case .pane(let id):
            guard let pane = services.pane(id: id) else { throw Self.gone }
            try reveal(pane, intent)
        case .workspace(let id):
            let workspace = services.machines.allWorkspaces.map(\.0).first { $0.resourceID?.rawValue == id }
            guard let workspace else { throw Self.gone }
            try reveal(workspace: workspace.id, intent)
        case .session(let id, let turn):
            try openSession(id, turn: turn, intent)
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
    /// shows it, else the daemon's default tab, else its first agent tab.
    private func selectedTab(of pane: PaneModel) -> String? {
        if let selected = services.paneController(for: pane)?.stripModel.selectedID { return selected.rawValue }
        guard !pane.tabs.isEmpty else { return services.agentTabs.tabIDs(in: pane.id).first }
        return pane.tabs[min(max(pane.defaultTabIndex, 0), pane.tabs.count - 1)].id
    }

    /// The palette workspace switcher's path: the window that lists the
    /// workspace shows it, and comes forward. Refused when no window could
    /// show it, never a silent success.
    private func reveal(workspace id: String, _ intent: WindowActivation.Intent) throws {
        guard let window = services.windows.reveal(workspaceID: id), let nsWindow = window.window else { throw Self.gone }
        services.showJumpWindow(nsWindow, intent)
    }

    /// Selects the tab that shows the session, else opens it in a new agent
    /// tab in the focused pane, whose page refuses a session the daemon does
    /// not have (native cannot list acpmux sessions synchronously). Then the
    /// page scrolls to the turn, a page not loaded yet once its row renders.
    private func openSession(_ id: String, turn: String?, _ intent: WindowActivation.Intent) throws {
        let tabs = services.agentTabs
        let key: String
        if let shown = tabs.tab(showing: id), services.revealTab(shown, intent: intent) {
            key = shown
        } else {
            guard let pane = services.windows.active?.focusedPane else { throw ActionFailure(message: MiscHandlerStrings.noPane) }
            key = pane.openAgentSession(id)
        }
        if let turn { tabs.revealTurn(turn, in: key) }
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

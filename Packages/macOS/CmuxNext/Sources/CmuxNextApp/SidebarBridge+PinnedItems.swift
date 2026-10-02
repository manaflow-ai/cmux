import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTabs
import Foundation

// Pinned tabs, pages and spaces in sidebar sections
// (plans/cmux-next/sidebar-sections.md 2). Each acts in this bridge's
// window: a tab is selected in its workspace, a page focuses a tab of the
// window's current space already showing it else opens in a new browser
// tab, and a space is shown in the window.
extension SidebarBridge {
    /// Selects a pinned tab in its workspace and focuses it. `ref` is the
    /// tab's id or its qualified `<session>:tab_…` form.
    func revealPinnedTab(_ ref: String) {
        guard let state, let (tab, pane) = pinnedTab(ref), let workspace = workspaceID(holding: pane) else { return }
        reveal(tab, in: pane, workspace: workspace, state: state)
    }

    /// Focuses a tab of this window's current space showing `text`, else
    /// opens it in a new browser tab of the focused pane, on the profile
    /// the workspace or the space sets (data-model.md 5).
    func openPinnedPage(_ text: String) {
        guard let state, let url = URL(string: text), url.scheme != nil else { return }
        if let (tab, pane, workspace) = openPage(url, in: state) {
            reveal(tab, in: pane, workspace: workspace, state: state)
            return
        }
        services.windows.controller(for: state.id)?.focusedPane?.newBrowserTab(url: url)
    }

    /// Shows the pinned space in this window; an unknown space does nothing.
    func switchToPinnedSpace(_ id: String) {
        let profile = ProfileID(rawValue: id)
        guard let state, services.machines.local.store.profileIDs.contains(profile) else { return }
        services.windows.switchProfile(profile, in: state)
    }

    /// The tab `ref` names: a tab with that id, else `<session>:<id>`
    /// looked up in that session's daemon.
    func pinnedTab(_ ref: String) -> (TabModel, PaneModel)? {
        if let found = services.locateTab(ref) { return found }
        guard let colon = ref.firstIndex(of: ":") else { return nil }
        let session = String(ref[..<colon]), id = String(ref[ref.index(after: colon)...])
        for daemon in services.machines.daemons where daemon.store.registryID == session {
            for pane in daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes) {
                if let tab = pane.tabs.first(where: { $0.id == id }) { return (tab, pane) }
            }
        }
        return nil
    }

    /// A browser tab showing `url` in the workspaces this window lists in
    /// its current space, the selected workspace first.
    func openPage(_ url: URL, in state: WindowState) -> (TabModel, PaneModel, String)? {
        let members = services.windows.registry.members(of: state.id)
        var ids = WindowProfiles.visible(members, profile: state.profileID, machines: services.machines)
        if let current = state.workspaceID, let index = ids.firstIndex(of: current) { ids.insert(ids.remove(at: index), at: 0) }
        for id in ids {
            guard let workspace = services.workspace(id: id) else { continue }
            for pane in workspace.screens.flatMap(\.panes) {
                for tab in pane.tabs where tab.kind == .browser {
                    let shown = services.cache.existingBrowser(tab.id)?.tab.state.url ?? tab.url.flatMap(URL.init(string:))
                    if let shown, Self.samePage(shown, url) { return (tab, pane, workspace.id) }
                }
            }
        }
        return nil
    }

    /// Whether two URLs are the same page: scheme and host compare
    /// case-insensitively, a trailing slash and the fragment are ignored.
    static func samePage(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String? {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.fragment = nil
            parts.scheme = parts.scheme?.lowercased()
            parts.host = parts.host?.lowercased()
            if parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
            if parts.path.isEmpty, parts.host != nil { parts.path = "/" }
            return parts.string
        }
        guard let left = key(a) else { return false }
        return left == key(b)
    }

    private func workspaceID(holding pane: PaneModel) -> String? {
        for (workspace, _) in services.machines.allWorkspaces where workspace.screens.contains(where: { $0.panes.contains { $0 === pane } }) {
            return workspace.id
        }
        return nil
    }

    /// Selects `tab` in this window: directly when its pane is on screen
    /// here, else through the window's selection memory and focus, then
    /// shows its workspace (switching space if it lives in another).
    private func reveal(_ tab: TabModel, in pane: PaneModel, workspace: String, state: WindowState) {
        if let shown = services.windows.controller(for: state.id)?.content?.pane(for: pane.handle), shown.pane === pane {
            shown.select(StripTabID(tab.id))
            return
        }
        state.selection.select(tab.id, in: pane.id)
        state.focus.send(.selectTab(pane: pane.id, tab: tab.id, workspace: workspace, source: .intent))
        services.windows.show(workspaceID: workspace, in: state)
    }
}

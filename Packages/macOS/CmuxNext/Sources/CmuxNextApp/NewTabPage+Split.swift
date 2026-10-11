import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// The tab key a split's page got from the store, for its Open Tabs moves.
private final class SplitPageKey {
    var value: String?
}

/// Split Right/Down from a browser tab, the New Tab page or an agent chat (cx-jfo7): the new pane
/// opens on the New Tab page instead of a terminal, with an Open Tabs list of the workspace's
/// tabs to move there. The page opens hidden in the source pane and then moves to a new split on
/// `edge`, the way a new chat reaches its dock (NewChatPlacement.dock).
extension NewTabPage {
    /// Whether a person's split of `pane` opens the New Tab page: its selected tab is a browser
    /// tab, the New Tab page or an agent chat. Terminal splits keep the terminal.
    static func splitsToPage(_ pane: PaneController?, direction: PaneDirection, byPerson: Bool) -> Bool {
        guard byPerson, direction == .right || direction == .down, let pane, let key = pane.currentTabKey else { return false }
        return NewTabKind.of(key, tab: pane.selectedTab, services: pane.services) != .terminal
    }

    static func split(_ source: PaneController, edge: PaneEdge) {
        let services = source.services
        let cwd = source.selectedTab?.cwd
        var page = Self.page(services, selected: source.selectedTab)
        page.openTabs = openTabs(services, in: source.pane)
        let opened = SplitPageKey()
        // The page moves to the new pane: its choices act in the pane that shows it now.
        var handler = Self.handler(services, cwd: cwd) { [weak services] key, request in
            guard let services, let pane = Self.hosting(key, services) else { return }
            Self.replace(key, with: request, cwd: request.cwd ?? cwd, in: pane)
        }
        let jump = handler.jump
        handler.jump = { [weak services] target, id in
            guard target == .here else { return jump(target, id) }
            if let services, let key = opened.value { Self.moveHere(id, page: key, services: services) }
        }
        _ = services.agentTabs.openTab(in: source, newTab: (page, handler), select: false, hidden: true) { [weak source] key in
            opened.value = key
            if let source { Self.moveToSplit(key, from: source, edge: edge) }
        }
    }

    /// The workspace's tabs as the Open Tabs list shows them, but New Tab pages.
    static func openTabs(_ services: AppServices, in pane: PaneModel) -> [AgentPaneOmnibar.Tab] {
        let workspace = services.machines.allWorkspaces.first { entry in
            entry.0.screens.contains { screen in screen.panes.contains { $0.handle == pane.handle } }
        }?.0
        return (workspace?.screens ?? []).flatMap(\.panes).flatMap(\.tabs).compactMap { tab in
            let agent = services.agentTabs.isAgentTab(tab.id)
            if agent, services.agentTabs.isNewTabPage(tab.id) { return nil }
            let kind: AgentPaneTabKind = agent ? .agent : tab.kind == .browser ? .browser : .terminal
            return AgentPaneOmnibar.Tab(
                id: tab.id, kind: kind, title: tab.displayTitle,
                detail: kind == .browser ? tab.url.map(Self.displayURL) : tab.cwd.map(Self.abbreviated),
                icon: kind == .browser ? AppServices.dataURL(services.tabFavicon(tab)) : nil
            )
        }
    }

    /// The pane showing tab `key` now.
    private static func hosting(_ key: String, _ services: AppServices) -> PaneController? {
        services.locateTab(key).flatMap { services.paneController(for: $0.1) }
    }

    /// Moves the hidden page `key` to a new pane on `edge` of its pane once the store lists it,
    /// then shows it there and focuses it. A failed move shows it where it is.
    private static func moveToSplit(_ key: String, from source: PaneController, edge: PaneEdge) {
        let services = source.services
        services.registry.track(Task { @MainActor [weak source] in
            if services.locateTab(key) == nil {
                for await located in ObservationStream({ services.locateTab(key) != nil }) where located { break }
            }
            guard case let (tab, pane)? = services.locateTab(key) else { return nil }
            TabMoves.toNewSplit(tab, pane: pane, edge: edge, services: services) { moved in
                guard let source else { return }
                source.dockFinished(key)
                guard moved, let content = source.workspace else { return }
                NewChatPlacement.focusWhenShown(key, in: content, leaving: source.layoutPaneID, services: services)
            }
            return nil
        })
    }

    /// The Open Tabs list picked tab `id`: it moves into the page's pane, where the page was,
    /// and the page closes once it has.
    private static func moveHere(_ id: String, page key: String, services: AppServices) {
        guard case let (tab, _)? = services.locateTab(id), tab.id != key, case let (_, pane)? = services.locateTab(key),
              let host = services.paneController(for: pane) else { return }
        let index = pane.tabs.firstIndex { $0.id == key } ?? pane.tabs.count
        host.selectWhenReported(surface: tab.surface)
        TabMoves.move(tab, to: pane, index: index, services: services) { [weak host] moved in
            if moved { host?.close([StripTabID(key)]) }
        }
    }
}

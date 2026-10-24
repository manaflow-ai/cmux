import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import enum CmuxNextLayout.NewChatPlacement

/// The tab key a split's page got from the store, for its Open Tabs moves.
private final class SplitPageKey {
    var value: String?
}

/// Split Right/Down from a browser tab, the New Tab page or an agent chat (cx-jfo7): the new pane
/// opens on the New Tab page instead of a terminal, with an Open Tabs list of the workspace's
/// tabs to move there. One daemon commit makes the page in the new pane (`conversation-tab-split-v1`:
/// one gesture, one transaction, one tree delta); an older daemon opens it hidden in the source pane
/// and then moves it to a new split on `edge`, the way a new chat reaches its dock (NewChatPlacement.dock).
extension NewTabPage {
    /// Whether a person's split of `pane` opens the New Tab page: its selected tab is a browser
    /// tab, the New Tab page or an agent chat. Terminal splits keep the terminal, and so does every
    /// split with `tabs.terminalFirst` on (#23021).
    static func splitsToPage(_ pane: PaneController?, direction: PaneDirection, byPerson: Bool) -> Bool {
        guard byPerson, direction == .right || direction == .down, let pane, let key = pane.currentTabKey,
              !NewTabKind.terminalFirst(pane.services) else { return false }
        return NewTabKind.of(key, tab: pane.selectedTab, services: pane.services) != .terminal
    }

    /// `focusesPage` false (a tab dropped on its own pane's edge, #22287): the page neither takes the
    /// keys nor focus; the dropped tab keeps them. `swapsBack`: once the page's pane is placed on `edge`,
    /// the two panes swap, so the page ends across from `edge` (as Split Left splits right, then swaps).
    /// Returns whether the page was started.
    @discardableResult
    static func split(_ source: PaneController, edge: PaneEdge, focusesPage: Bool = true, swapsBack: Bool = false) -> Bool {
        let services = source.services
        var page = Self.page(services, selected: source.selectedTab, pane: source)
        let cwd = page.cwd
        page.openTabs = openTabs(services, in: source.pane)
        let opened = SplitPageKey()
        // Keys typed after the split wait for the new page's field, in order (cx-kql5h): the page
        // is made, moved to the new pane and shown before it can take them.
        let input = services.keyRouter.newTabInputCoordinator
        let keys = focusesPage ? input.beginIncoming(in: source.view.window) : nil
        page.inputToken = keys
        if let keys { input.attachIncoming(keys) }
        // The page moves to the new pane: its choices act in the pane that shows it now.
        var handler = Self.handler(services, cwd: cwd) { [weak services] key, request in
            guard let services, let pane = Self.hosting(key, services) else { return }
            Self.replace(key, with: request, cwd: request.cwd ?? cwd, in: pane)
        }
        handler.inputReady = { [weak input] key, token in input?.pageReady(token, key: key) }
        let jump = handler.jump
        handler.jump = { [weak services] target, id in
            guard target == .here else { return jump(target, id) }
            if let services, let key = opened.value { Self.moveHere(id, page: key, services: services) }
        }
        let split: SplitDirection? = !source.daemon.supports(DaemonCapability.conversationTabSplit.rawValue) ? nil
            : edge == .right ? .right : edge == .bottom ? .down : nil
        // Even split sizing, as a terminal split (PaneHandlers.split), once the store's pane is placed.
        let sizing = split.flatMap { source.workspace?.layoutModel.splitSizingChanges(splitting: source.layoutPaneID, axis: $0 == .right ? .horizontal : .vertical) } ?? []
        // Shown with the split, in this frame (one spring for the whole chain); sent once the page is placed.
        let layoutModel = source.workspace?.layoutModel
        let shownSizing = split == nil ? nil : layoutModel?.showSplitSizing(sizing)
        // A refused or cancelled page: the split's sizing goes, and the held keys go now, not at the hold's own limit.
        let release = { [weak input] in
            if let shownSizing { layoutModel?.cancelSplitSizing(shownSizing) }
            input?.endIncoming(keys, pageMade: false)
        }
        let started = services.agentTabs.openTab(in: source, newTab: (page, handler), select: false, hidden: split == nil, split: split,
                                                 focuses: focusesPage) { [weak source] key in
            opened.value = key
            guard let source else { return }
            guard let split else { return Self.moveToSplit(key, from: source, edge: swapsBack ? edge.opposite : edge, keys: keys, focuses: focusesPage) }
            if let shownSizing { layoutModel?.commitSplitSizing(shownSizing) }
            if swapsBack { source.daemon.send("swap-pane") { [handle = source.pane.handle] in try await $0.swapPane(handle, with: .direction(split == .right ? .right : .down)) } }
            input.flushAll() // the page shows in its pane: a field that reported ready may take the keys now
        } failed: { release() }
        if !started { release() }
        // The split's provisional pane is in the store: the window lays it out and mounts it in
        // this turn, so the page's pane draws in the key's frame (instant-new-surfaces).
        if started, split != nil { BenchSpans.measure("split.layout") { source.workspace?.applyCurrent() } }
        return started
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
            // An untitled shell is named by its folder, a page by its address, as the bar names them.
            let title = Self.place(tab, home: NSHomeDirectory())?.title ?? tab.displayTitle
            return AgentPaneOmnibar.Tab(
                id: tab.id, kind: kind, title: title,
                detail: kind == .browser ? tab.url.map(Self.displayURL) : tab.cwd.map { Self.abbreviated($0) },
                icon: kind == .browser ? AppServices.dataURL(services.tabFavicon(tab)) : nil
            )
        }
    }

    /// The pane showing tab `key` now.
    /// The pane that shows page `key` now (it may have moved since it opened).
    static func hosting(_ key: String, _ services: AppServices) -> PaneController? {
        services.locateTab(key).flatMap { services.paneController(for: $0.1) }
    }

    /// Moves the hidden page `key` to a new pane on `edge` of its pane once the store lists it,
    /// then shows it there and focuses it. A failed move shows it where it is.
    private static func moveToSplit(_ key: String, from source: PaneController, edge: PaneEdge, keys: String?, focuses: Bool) {
        let services = source.services
        services.registry.track(Task { @MainActor [weak source] in
            if services.locateTab(key) == nil {
                for await located in ObservationStream({ services.locateTab(key) != nil }) where located { break }
            }
            guard case let (tab, pane)? = services.locateTab(key) else { return nil }
            TabMoves.toNewSplit(tab, pane: pane, edge: edge, services: services, keepFocus: !focuses) { moved in
                let input = services.keyRouter.newTabInputCoordinator
                // A failed move leaves the page unselected in its pane: the held keys go on now.
                guard let source else { return input.endIncoming(keys, pageMade: false) }
                source.dockFinished(key)
                guard moved, let content = source.workspace else { return input.endIncoming(keys, pageMade: false) }
                if focuses { NewChatPlacement.focusWhenShown(key, in: content, leaving: source.layoutPaneID, services: services) }
                // The page shows in its new pane: a field that reported ready may take the keys now.
                input.flushAll()
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

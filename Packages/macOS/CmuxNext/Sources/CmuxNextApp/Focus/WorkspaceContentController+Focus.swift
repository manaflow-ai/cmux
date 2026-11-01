import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextFocus

// The focus topology of the shown workspace and the helpers creation paths
// use to ask for focus on something that lands later.
extension WorkspaceContentController {
    /// Tells the coordinator the current panes, tabs and selections. While
    /// `apply` runs it sends once, at its end. The coordinator drops a
    /// topology equal to the one it holds.
    func sendTopology(_ file: StaticString = #fileID, _ line: UInt = #line) {
        guard !isParked, !isApplying else { return }
        focus.topologySent(by: self)
        #if DEBUG
        DebugLayoutCounters.topologySends &+= 1
        debugTopologySends &+= 1
        DebugLayoutCounters.note("topology", file, line)
        #endif
        focus.send(.topology(focusTopology()))
        rekeySurfaceWait() // a tab this topology adds may be the one a surface wait names
    }

    /// Topologies name tabs by id only: a wait by a daemon surface takes its tab's id (same target, pane, generation)
    /// once the store has it: at each topology send (a new tab) and at a split's confirm (`terminalConfirmed`).
    func rekeySurfaceWait() {
        guard let wait = focus.state.expectation, case .surface(let raw) = wait.key, let value = UInt64(raw),
              let tab = daemon.store.tab(surface: SurfaceID(rawValue: value)) else { return }
        focus.expect(.tab(tab.id), target: wait.target, awayFrom: wait.awayFrom, generation: wait.generation)
    }

    /// A pane's part of the topology changed: every pane that changes in this main-actor turn
    /// shares one build and send (`FocusCoordinator.setNeedsTopology`), not one each (I4).
    func setNeedsTopology(_ file: StaticString = #fileID, _ line: UInt = #line) {
        guard !isParked, !isApplying else { return }
        focus.setNeedsTopology(owner: self) { [weak self] in
            guard let self, !self.isParked, !self.isApplying else { return nil }
            #if DEBUG
            DebugLayoutCounters.topologySends &+= 1
            self.debugTopologySends &+= 1
            DebugLayoutCounters.note("topology", file, line)
            #endif
            self.rekeySurfaceWait() // lands on this topology when it adds the tab (the reducer keeps the wait)
            return self.focusTopology()
        }
    }

    /// Panes in layout order (every screen, in screen order). A pane whose
    /// controller exists reports its strip; others report the daemon tabs
    /// and the remembered selection.
    func focusTopology() -> FocusTopology {
        var panes: [FocusTopology.Pane] = []
        for id in layoutModel.screens.flatMap(\.layout.panes) {
            if let controller = self.panes[id] {
                panes.append(controller.focusPane)
                continue
            }
            guard let handle = handles.panes[id], let model = daemon.store.pane(handle) else { continue }
            let tabs = model.tabs.map { FocusTopology.Tab(id: $0.id, kind: .of($0)) }
            let selected = state.selection.selection(in: model.id).flatMap { id in tabs.contains { $0.id == id } ? id : nil }
                ?? (tabs.isEmpty ? nil : tabs[min(max(model.defaultTabIndex, 0), tabs.count - 1)].id)
            panes.append(FocusTopology.Pane(id: id.rawValue, tabs: tabs, selected: selected))
        }
        let screens = layoutModel.screens.map { screen -> [FocusTopology.Column] in
            switch screen.layout {
            case .splits(let root): [FocusTopology.Column(id: screen.id.rawValue, panes: root.panes.map(\.rawValue))]
            case .columns:
                screen.layout.visualColumns.map { FocusTopology.Column(id: $0.id.rawValue, panes: $0.root.panes.map(\.rawValue)) }
            }
        }
        return FocusTopology(workspace: workspace.id, panes: panes, screens: screens)
    }

    /// The shown workspace's focus history, newest first (focus.md 4a).
    var recentPanes: [LayoutPaneID] {
        focus.recentPanes().map(LayoutPaneID.init(rawValue:))
    }

    /// The daemon pane shown as layout pane `key` (its controller's, else the store's).
    func paneModel(key: String) -> PaneModel? {
        let id = LayoutPaneID(key)
        if let controller = panes[id] { return controller.pane }
        return handles.panes[id].flatMap(daemon.store.pane)
    }

    /// Focuses the most recently focused pane of `screen`, else its first.
    func focusRememberedPane(on screen: LayoutScreenID) {
        guard let panes = layoutModel.screens.first(where: { $0.id == screen })?.layout.panes,
              let pane = FocusNavigation.mostRecent(panes, recency: recentPanes) ?? panes.first else { return }
        // Keep the layout model's shown screen and pane in sync immediately.
        // The focus coordinator may not have this newly mirrored pane in its
        // topology yet, so waiting for its effect would let a later topology
        // echo restore the previously shown screen.
        layoutModel.focus(pane, notify: false)
        focus.send(.focusPane(pane.rawValue, source: .intent))
    }

    /// Starts a user intent whose result lands later.
    func beginFocusIntent() -> UInt64 { focus.beginIntent() }

    /// A close cancelled a pending split (`CancelledCreation`): the store took its stand-in out in this turn, so the window
    /// shows that now, not at its store observation a turn later, and the focus reducer gives the stand-in's successor
    /// (the pane it was split from) the focus at once: the next key never acts on the closed stand-in (P0 STATUS 1584).
    func showCancelledCreation() {
        if panes.values.contains(where: { daemon.store.pane($0.pane.handle) == nil }) { applyCurrent() }
    }

    /// Focuses `surface` once the daemon reports it, unless the user acted
    /// after `generation` (nil: app-driven, no intent). `awayFrom`: only
    /// once it left that pane (a tab created there and moved away).
    func expectFocus(on surface: SurfaceID, target: FocusState.Target = .content, awayFrom paneKey: String? = nil,
                     generation: UInt64? = nil) {
        // The coordinator lands an expectation against the topology it holds at once (reducer
        // `Expect`), and again on each later topology: no re-apply or topology send here.
        // The topology names tabs by id: a tab the store has goes by its id; else `rekeySurfaceWait` later.
        let key: FocusState.Expectation.Key = daemon.store.tab(surface: surface).map { .tab($0.id) } ?? .surface(String(surface.rawValue))
        focus.expect(key, target: target, awayFrom: paneKey, generation: generation)
    }
}

extension FocusTopology.Kind {
    static func of(_ tab: TabModel) -> FocusTopology.Kind {
        // An agent chat tab is a conversation tab on an acpmux session; its content is the agent page.
        // A page tab is a conversation tab with a page source, an app tab (`app-screens-v1`) a frontend
        // tab with an app; the content of both is an internal page.
        tab.agentSession != nil ? .agent : (tab.page != nil || tab.appTab != nil) ? .page : of(tab.kind, isFrontendOwned: tab.isFrontendOwned)
    }

    static func of(_ kind: TabKind, isFrontendOwned: Bool) -> FocusTopology.Kind {
        switch kind {
        case .pty, .remoteTerminal: .terminal
        case .browser where isFrontendOwned: .browser
        case .conversation: .conversation
        default: .other
        }
    }
}

extension PaneController {
    /// This pane as the focus topology sees it: strip order (pending closes
    /// hidden, session browser tabs included) and the selected tab.
    var focusPane: FocusTopology.Pane {
        // One pass over the pane's tabs, not one per strip tab (cx-6so.21).
        let byID = Dictionary(pane.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tabs = stripModel.orderedTabs.map { item -> FocusTopology.Tab in
            let id = item.id.rawValue
            if id.hasPrefix(LocalBrowserTab.prefix) { return FocusTopology.Tab(id: id, kind: .browser) }
            if id.hasPrefix(LocalPageTab.prefix) { return FocusTopology.Tab(id: id, kind: .page) }
            return byID[id].map { FocusTopology.Tab(id: id, kind: .of($0)) } ?? FocusTopology.Tab(id: id, kind: .other)
        }
        return FocusTopology.Pane(id: paneKey, tabs: tabs, selected: stripModel.selectedID?.rawValue)
    }
}

extension WorkspaceContentController {
    /// Every tab of every screen's panes, in layout order: its id and its daemon tab, looked
    /// up in this workspace's own store (nil for a session-local browser tab).
    func tabsInLayoutOrder() -> [(id: String, model: TabModel?)] {
        focusTopology().panes.flatMap { pane in
            let id = LayoutPaneID(pane.id)
            let models = panes[id]?.pane.tabs ?? handles.panes[id].flatMap(daemon.store.pane)?.tabs ?? []
            let byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return pane.tabs.map { tab in (tab.id, byID[tab.id]) }
        }
    }
}

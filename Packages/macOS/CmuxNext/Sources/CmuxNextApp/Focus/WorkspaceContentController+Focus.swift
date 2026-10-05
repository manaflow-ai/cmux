import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextLayout

// The focus topology of the shown workspace and the helpers creation paths
// use to ask for focus on something that lands later.
extension WorkspaceContentController {
    /// Tells the coordinator the current panes, tabs and selections.
    func sendTopology() {
        guard !isParked else { return }
        focus.send(.topology(focusTopology()))
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
            let tabs = model.tabs.map { FocusTopology.Tab(id: $0.id, surface: String($0.surface.rawValue), kind: .of($0)) }
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
        focus.state.recentPanes.map(LayoutPaneID.init(rawValue:))
    }

    /// Focuses the most recently focused pane of `screen`, else its first.
    func focusRememberedPane(on screen: LayoutScreenID) {
        guard let panes = layoutModel.screens.first(where: { $0.id == screen })?.layout.panes,
              let pane = FocusNavigation.mostRecent(panes, recency: recentPanes) ?? panes.first else { return }
        focus.send(.focusPane(pane.rawValue, source: .intent))
    }

    /// Starts a user intent whose result lands later.
    func beginFocusIntent() -> UInt64 { focus.beginIntent() }

    /// Focuses `surface` once the daemon reports it, unless the user acted
    /// after `generation` (nil: app-driven, no intent). `awayFrom`: only
    /// once it left that pane (a tab created there and moved away).
    func expectFocus(on surface: SurfaceID, target: FocusState.Target = .content, awayFrom paneKey: String? = nil,
                     generation: UInt64? = nil) {
        focus.expect(.surface(String(surface.rawValue)), target: target, awayFrom: paneKey, generation: generation)
        applyCurrent()
    }
}

extension FocusTopology.Kind {
    static func of(_ tab: TabModel) -> FocusTopology.Kind {
        // An agent chat tab is a conversation tab on an acpmux session; its content is the agent page.
        tab.agentSession != nil ? .agent : of(tab.kind, isFrontendOwned: tab.isFrontendOwned)
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
        let tabs = stripModel.orderedTabs.map { item -> FocusTopology.Tab in
            let id = item.id.rawValue
            if id.hasPrefix(LocalBrowserTab.prefix) { return FocusTopology.Tab(id: id, kind: .browser) }
            if id.hasPrefix(LocalPageTab.prefix) { return FocusTopology.Tab(id: id, kind: .page) }
            guard let tab = pane.tabs.first(where: { $0.id == id }) else { return FocusTopology.Tab(id: id, kind: .other) }
            return FocusTopology.Tab(id: id, surface: String(tab.surface.rawValue), kind: .of(tab))
        }
        return FocusTopology.Pane(id: paneKey, tabs: tabs, selected: stripModel.selectedID?.rawValue)
    }
}

public import CmuxNextDaemon

/// Maps the daemon mirror into the control socket's value topology. Pure;
/// the publisher calls it inside Observation tracking so every property it
/// reads schedules the next publish when it changes.
extension ControlTabInfo {
    func withTerminalResource(_ id: String?) -> ControlTabInfo {
        var info = self
        info.terminalResourceID = id
        return info
    }
}

/// What the app knows of page tabs that the daemon tree does not
/// (bd cx-5xsi): a pane's app-only page tabs and each page's title.
public struct ControlPageFacts {
    public var appOnlyTabs: @MainActor (PaneModel) -> [ControlPageTabInfo]
    /// A store page tab's title, as its strip names it (a Files tab names
    /// its file); nil when unknown.
    public var title: @MainActor (TabModel) -> String?
    /// The browser tabs of other panes a pane's strip also lists (`browser.page.mirror`), in strip order.
    public var mirroredTabs: @MainActor (PaneModel) -> [String]

    public init(appOnlyTabs: @escaping @MainActor (PaneModel) -> [ControlPageTabInfo] = { _ in [] },
                title: @escaping @MainActor (TabModel) -> String? = { _ in nil },
                mirroredTabs: @escaping @MainActor (PaneModel) -> [String] = { _ in [] }) {
        self.appOnlyTabs = appOnlyTabs
        self.title = title
        self.mirroredTabs = mirroredTabs
    }
}

extension ControlTopology {
    /// The topology of `store`'s tree. `selectedTab` answers the tab a window
    /// shows for a pane (app-local); `pages` what the app knows of page tabs
    /// (bd cx-5xsi); `cache` keeps each workspace's daemon facts between calls.
    @MainActor
    public init(store: DaemonStore, selectedTab: (PaneModel) -> String?, pages: ControlPageFacts = ControlPageFacts(),
                cache: ControlWorkspaceInfoCache? = nil, scope: ControlAppFactScope? = nil) {
        self = ControlTopologyMapper.topology(store: store, selectedTab: selectedTab, pages: pages, cache: cache, scope: scope)
    }

    /// The control values of another store's workspaces (a remote session),
    /// `decorate` applied to each (its session id and machine). With `cache`
    /// and `scope`, kept under `slot` and mapped like the home store's
    /// (``ControlWorkspaceInfoCache/workspaces(of:slot:scope:selectedTab:pages:decorate:)``);
    /// otherwise every workspace is mapped whole.
    ///
    /// - Parameters:
    ///   - store: the daemon mirror whose workspaces are listed.
    ///   - cache: keeps the values between calls; nil maps every workspace.
    ///   - slot: the key the list is kept under; `decorate` must give the same values for a slot.
    ///   - scope: the panes whose app facts can be set; nil maps every workspace.
    ///   - selectedTab: the tab a window shows for a pane.
    ///   - pages: what the app knows of page tabs.
    ///   - decorate: applied to each workspace's value.
    /// - Returns: one value per workspace, in the store's order.
    @MainActor
    public static func workspaces(of store: DaemonStore, cache: ControlWorkspaceInfoCache?, slot: String, scope: ControlAppFactScope?,
                                  selectedTab: (PaneModel) -> String?, pages: ControlPageFacts = ControlPageFacts(),
                                  decorate: (inout ControlWorkspaceInfo) -> Void) -> [ControlWorkspaceInfo] {
        if let cache, let scope {
            return cache.workspaces(of: store, slot: slot, scope: scope, selectedTab: selectedTab, pages: pages, decorate: decorate)
        }
        return store.workspaces.map { model in
            var info = ControlTopologyMapper.workspace(from: model, selectedTab: selectedTab, pages: pages)
            decorate(&info)
            return info
        }
    }
}

extension ControlWorkspaceInfoCache {
    /// The control values of `store`'s workspaces, kept under `slot` (one
    /// per store): a publish maps only the workspaces that changed and the
    /// ones `scope` names (``ControlAppFactScope``). `selectedTab` and
    /// `pages` answer the app facts as for ``ControlTopology/init(store:selectedTab:pages:cache:scope:)``;
    /// `decorate` sets facts the store does not hold (a remote session's id
    /// and machine) on each daemon value, and must give the same result on
    /// every call for a slot.
    ///
    /// - Parameters:
    ///   - store: the daemon mirror whose workspaces are listed.
    ///   - slot: the key the list is kept under between publishes.
    ///   - scope: the workspaces whose app facts can differ from their daemon facts.
    ///   - selectedTab: the tab a window shows for a pane.
    ///   - pages: what the app knows of page tabs.
    ///   - decorate: applied to each workspace's daemon value.
    /// - Returns: one value per workspace, in the store's order.
    @MainActor
    public func workspaces(of store: DaemonStore, slot: String, scope: ControlAppFactScope,
                           selectedTab: (PaneModel) -> String?, pages: ControlPageFacts = ControlPageFacts(),
                           decorate: (inout ControlWorkspaceInfo) -> Void = { _ in }) -> [ControlWorkspaceInfo] {
        ControlTopologyMapper.workspaces(of: store, cache: self, slot: slot, scope: scope, selectedTab: selectedTab,
                                         pages: pages, decorate: decorate)
    }
}

extension ControlWorkspaceInfo {
    /// `model`'s control value: the daemon facts from `cache` (built without
    /// app facts), then the app facts applied fresh; no cache maps it whole.
    @MainActor
    public init(_ model: WorkspaceModel, cache: ControlWorkspaceInfoCache?, selectedTab: (PaneModel) -> String?,
                pages: ControlPageFacts) {
        self = ControlTopologyMapper.cachedWorkspace(from: model, cache: cache, selectedTab: selectedTab, pages: pages)
    }
}

/// A pane of a cached workspace value, captured when the entry was built
/// (cx-1ox9m): the publisher applies app facts from it without reading the
/// workspace tree again. `pageTabs` is empty for a pane without page tabs,
/// else one element per tab (the store page tabs, nil for the others).
struct ControlPaneSlot {
    let pane: PaneModel
    let pageTabs: [TabModel?]
}

@MainActor
enum ControlTopologyMapper {
    static func topology(store: DaemonStore, selectedTab: (PaneModel) -> String?,
                         pages: ControlPageFacts = ControlPageFacts(),
                         cache: ControlWorkspaceInfoCache? = nil, scope: ControlAppFactScope? = nil) -> ControlTopology {
        var topology = ControlTopology()
        topology.isLoaded = store.isLoaded
        topology.daemonState = switch store.connectionState {
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .failed: "failed"
        }
        // The groups the sidebar draws: the home session's personal groups
        // when it serves them (cx-qno.17), else the daemon's shared groups.
        let groups = store.personal.isLoaded ? store.personal.groups : store.groups
        topology.workspaceGroups = groups.map { group in
            ControlWorkspaceGroupInfo(id: group.id.rawValue, name: group.name, color: group.color, isCollapsed: group.collapsed)
        }
        if let cache, let scope {
            topology.workspaces = cache.workspaces(of: store, slot: ControlWorkspaceInfoCache.homeSlot, scope: scope, selectedTab: selectedTab, pages: pages)
        } else {
            topology.workspaces = store.workspaces.map { model in
                cachedWorkspace(from: model, cache: cache, selectedTab: selectedTab, pages: pages)
            }
        }
        return topology
    }

    /// `store`'s workspaces through `cache`'s list under `slot`, `decorate`
    /// applied to each value (a remote session's id and machine).
    static func workspaces(of store: DaemonStore, cache: ControlWorkspaceInfoCache, slot: String, scope: ControlAppFactScope,
                           selectedTab: (PaneModel) -> String?, pages: ControlPageFacts,
                           decorate: (inout ControlWorkspaceInfo) -> Void) -> [ControlWorkspaceInfo] {
        cache.workspaces(slot: slot, list: { store.workspaces }, scope: scope, build: { model in
            var info = workspace(from: model, selectedTab: { _ in nil }, pages: ControlPageFacts())
            decorate(&info)
            return (info, slots(of: model))
        }, appFacts: { model, info, slots in
            if let applied = applyAppFacts(info, slots: slots, selectedTab: selectedTab, pages: pages) { return applied }
            var info = workspace(from: model, selectedTab: selectedTab, pages: pages)
            decorate(&info)
            return info
        })
    }

    static func cachedWorkspace(from model: WorkspaceModel, cache: ControlWorkspaceInfoCache?,
                                selectedTab: (PaneModel) -> String?, pages: ControlPageFacts) -> ControlWorkspaceInfo {
        guard let cache else { return workspace(from: model, selectedTab: selectedTab, pages: pages) }
        let cached = cache.info(for: model) { model in
            (workspace(from: model, selectedTab: { _ in nil }, pages: ControlPageFacts()), slots(of: model))
        }
        return applyAppFacts(cached.info, slots: cached.slots, selectedTab: selectedTab, pages: pages)
            ?? workspace(from: model, selectedTab: selectedTab, pages: pages)
    }

    /// `model`'s panes as `workspace(from:)` lists them, screen by screen.
    /// Read in the same tracking as the entry's value, so they line up.
    static func slots(of model: WorkspaceModel) -> [[ControlPaneSlot]] {
        model.screens.map { screen in
            screen.panes.map { pane in
                let tabs = pane.tabs
                guard tabs.contains(where: { $0.page != nil }) else { return ControlPaneSlot(pane: pane, pageTabs: []) }
                return ControlPaneSlot(pane: pane, pageTabs: tabs.map { $0.page != nil ? $0 : nil })
            }
        }
    }

    /// Sets the facts the app owns and Observation does not track: each
    /// pane's shown tab and app-only page tabs, and store page tab titles.
    /// O(panes + tabs of panes with page tabs); reads no workspace, screen,
    /// pane or tab property of the tree (the cache entry's own tracking
    /// covers those). Nil when `slots` does not line up with `info`.
    static func applyAppFacts(_ info: ControlWorkspaceInfo, slots: [[ControlPaneSlot]],
                              selectedTab: (PaneModel) -> String?, pages: ControlPageFacts) -> ControlWorkspaceInfo? {
        guard info.screens.count == slots.count else { return nil }
        // Most workspaces are not shown and have no page tabs: their app facts
        // equal the cached value, which is returned without copying its
        // screens (every publish maps every workspace; 1,000 copies were most
        // of the main-thread stalls in the 2026-10-14 stress bench).
        if appFactsUnchanged(info, slots: slots, selectedTab: selectedTab, pages: pages) { return info }
        var aligned = true
        var info = info
        info.screens = zip(info.screens, slots).map { screen, panes in
            guard screen.panes.count == panes.count else { aligned = false; return screen }
            var screen = screen
            screen.panes = zip(screen.panes, panes).map { pane, slot in
                var pane = pane
                pane.selectedTabID = selectedTab(slot.pane)
                pane.pageTabs = pages.appOnlyTabs(slot.pane)
                pane.mirroredTabIDs = pages.mirroredTabs(slot.pane)
                guard !slot.pageTabs.isEmpty else { return pane }
                guard pane.tabs.count == slot.pageTabs.count else { aligned = false; return pane }
                pane.tabs = zip(pane.tabs, slot.pageTabs).map { tab, model in
                    guard let model, let title = pages.title(model) else { return tab }
                    var tab = tab
                    tab.title = title
                    return tab
                }
                return pane
            }
            return screen
        }
        return aligned ? info : nil
    }

    /// True when `applyAppFacts` would change nothing in `info` (false also
    /// when `slots` does not line up, so the full path decides).
    private static func appFactsUnchanged(_ info: ControlWorkspaceInfo, slots: [[ControlPaneSlot]],
                                          selectedTab: (PaneModel) -> String?, pages: ControlPageFacts) -> Bool {
        // Index loops, not zip: a debug build does not specialize zip and paid
        // generic metadata lookups per element on every publish.
        for screenIndex in info.screens.indices {
            guard let screen = info.screens[checked: screenIndex], let paneSlots = slots[checked: screenIndex],
                  screen.panes.count == paneSlots.count else { return false }
            for paneIndex in paneSlots.indices {
                guard let pane = screen.panes[checked: paneIndex], let slot = paneSlots[checked: paneIndex],
                      pane.selectedTabID == selectedTab(slot.pane), pane.pageTabs == pages.appOnlyTabs(slot.pane),
                      pane.mirroredTabIDs == pages.mirroredTabs(slot.pane) else { return false }
                guard !slot.pageTabs.isEmpty else { continue }
                guard pane.tabs.count == slot.pageTabs.count else { return false }
                for tabIndex in slot.pageTabs.indices {
                    guard let model = slot.pageTabs[checked: tabIndex] ?? nil, let title = pages.title(model) else { continue }
                    if title != pane.tabs[checked: tabIndex]?.title { return false }
                }
            }
        }
        return true
    }

    static func workspace(from model: WorkspaceModel, selectedTab: (PaneModel) -> String?,
                          pages: ControlPageFacts = ControlPageFacts()) -> ControlWorkspaceInfo {
        var info = ControlWorkspaceInfo(
            id: model.id,
            handle: model.handle.description,
            name: model.displayName,
            title: model.title,
            color: model.color,
            icon: model.icon,
            groupID: model.group?.rawValue,
            unreadCount: model.unreadCount,
            screens: model.screens.map { screen in
                let placed = columns(of: screen)
                var info = ControlScreenInfo(id: screen.id, handle: screen.handle.description, name: screen.name,
                                             zoomedPaneID: screen.zoomedPane.flatMap { handle in screen.pane(handle)?.id },
                                             panes: screen.panes.map { model in
                                                 var info = pane(from: model, selectedTab: selectedTab, pages: pages)
                                                 let handle = model.handle
                                                 info.column = placed.isEmpty ? 0 : placed.firstIndex { $0.panes.contains(handle) }
                                                 info.dock = placed.first { $0.panes.contains(handle) }?.dock
                                                 return info
                                             })
                info.defaultPaneID = screen.defaultPane.flatMap { handle in screen.pane(handle)?.id }
                return info
            }
        )
        info.resourceID = model.resourceID?.rawValue
        info.kind = model.kind
        return info
    }

    /// `screen`'s columns as the window draws them, left to right: left
    /// docks, the scrolling strip, right docks. Top and bottom bands span the
    /// screen and are no column. Empty for a screen stored as one split tree.
    static func columns(of screen: ScreenModel) -> [(panes: Set<PaneID>, dock: String?)] {
        let order: (ColumnSnapshot) -> Int? = { column in
            switch column.dock?.edge {
            case .left: 0
            case nil: 1
            case .right: 2
            case .top, .bottom: nil
            }
        }
        let placed = screen.columns.compactMap { column in order(column).map { (rank: $0, column: column) } }
        return placed.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map { (panes: Set($0.element.column.layout.paneIDs), dock: $0.element.column.dock?.edge.rawValue) }
    }

    static func pane(from model: PaneModel, selectedTab: (PaneModel) -> String?,
                     pages: ControlPageFacts = ControlPageFacts()) -> ControlPaneInfo {
        var info = ControlPaneInfo(
            id: model.id,
            handle: model.handle.description,
            name: model.name,
            selectedTabID: selectedTab(model),
            tabs: model.tabs.map { tab($0, pages: pages) },
            tabGroups: model.tabGroups.map { group in
                ControlTabGroupInfo(id: group.id.rawValue, name: group.name, color: group.color, isCollapsed: group.collapsed,
                                    memberIDs: group.members.map { member in
                                        switch member {
                                        case .surface(let surface): model.tabs.first { $0.surface == surface }?.id ?? surface.description
                                        case .tab(let resource): resource.rawValue
                                        }
                                    })
            }
        )
        info.pageTabs = pages.appOnlyTabs(model)
        info.mirroredTabIDs = pages.mirroredTabs(model)
        return info
    }

    static func tab(_ model: TabModel, pages: ControlPageFacts = ControlPageFacts()) -> ControlTabInfo {
        let kind = switch model.kind {
        case .pty: "terminal"
        case .browser: "browser"
        case .remoteTerminal: "remote-terminal"
        case .conversation: "conversation"
        case .other(let value): value
        }
        var info = ControlTabInfo(
            id: model.id,
            surface: model.surface.description,
            kind: kind,
            title: model.displayTitle,
            name: model.name,
            terminalID: model.terminalID?.rawValue,
            columns: model.size?.cols,
            rows: model.size?.rows,
            cwd: model.cwd,
            url: model.url,
            gitBranch: model.gitBranch,
            isPinned: model.pinned,
            isDead: model.dead,
            hasUnread: model.showsUnread,
            tabGroupID: model.tabGroup?.rawValue,
            agentState: model.agent?.state.rawValue
        ).withTerminalResource(model.terminalResourceID?.rawValue)
        info.agent = model.agent?.agent
        // Hook bookkeeping values (`cmux-hook-sequence:`, `cmux-hook-ended:`) are not a session.
        info.agentHarnessSessionID = model.agent?.harnessSessionID
        info.remoteSessionID = model.remote?.sessionID
        info.remoteTerminalID = model.remote?.terminalID.rawValue
        if model.kind == .browser { info.browserProfileID = model.browserProfileID ?? "default" }  // tracked: a move re-publishes
        info.agentSessionID = model.agentSession?.session
        // A store page tab (`page-tabs-v1`): the daemon titles it about:blank; the page names it.
        if let page = model.page {
            info.page = page
            if let title = pages.title(model) { info.title = title }
        }
        return info
    }
}

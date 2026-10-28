import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextLayout
import CmuxNextPages
import CmuxNextTabs
import CmuxNextWakeups
import Observation
import CmuxNextFocus

/// Mirrors one daemon pane into a tab strip and shows the selected tab's
/// content. Tab selection is client-local (`WindowState.selection`); every
/// other change is a daemon command (PaneController+Intents).
final class PaneController: SurfacePresenter, PresentablePane {
    let paneKey: String
    let layoutPaneID: LayoutPaneID
    var pane: PaneModel // set only by adopt(_:): a resync's new record of the same pane
    /// The machine daemon that owns `pane`.
    let daemon: DaemonService
    let stripModel = TabStripModel()
    let view: PaneContentView
    unowned let services: AppServices
    /// Weak: daemon round trips (`Task`s in the intents) can outlive the
    /// window, and a closed window frees its state.
    weak var state: WindowState?
    weak var workspace: WorkspaceContentController?

    private(set) var currentTabKey: String?
    /// How near the layout reports this pane to the viewport.
    private(set) var presence: SurfacePresence = .hidden
    var isVisible: Bool { presence == .visible }
    var showsNewTabs: Bool { view.window != nil && !isSuspended && ActionRunScope.viewChangeAllowed() } // a tab created now shows: create.tab begins (p09-observability 030)
    var pendingDock: Set<String> = [] // chats bound for a new chat dock, never in this strip (NewChatPlacement)
    /// A tab this app just created here; selected once the daemon reports it (`selectWhenReported`).
    var pendingSelectSurface: SurfaceID? { didSet { if let oldValue, oldValue != pendingSelectSurface { services.cache.createTabs.dropped(surface: oldValue.rawValue) } } } // set by selectWhenReported* (AgentBesidePlacement); one replaced before it is listed ends its create.tab wait unsampled
    /// Same, named by tab resource id (a reopened tab's restored view).
    private(set) var pendingSelectTab: String?
    private var observation: Task<Void, Never>?
    /// One observation per daemon tab's strip item and focus kind (`focusPane` reads it; I1, I2).
    private lazy var tabItems = ObservedItems<TabModel, (StripTabItem, FocusTopology.Kind)>(
        item: { [weak self] tab in self.map { ($0.tabItem(tab), FocusTopology.Kind.of(tab)) } },
        same: { $0.0 == $1.0 && $0.1 == $1.1 }, changed: { [weak self] in self?.tabItemChanged() })
    /// The strip's selected tab as last set, unobserved: a tab switch does not re-run `snapshot()` (I2).
    private(set) var stripSelection: String?
    private var sentFocusPane: FocusTopology.Pane? // this pane's topology part as last sent (I4)
    private(set) var appliedRecordTabs: [String] = [] // the record's tab ids at the last apply: a record that differs is a stale strip (`syncStripIfStale`)
    private var closeTabs: [(SurfaceID, String)] = [] // the tabs of the last apply: a closed tab's opener picks its successor (BrowserTabOpeners.closeRelations)
    private var remapsViewedTab = false // a newly selected tab lost its attention dot: map the strip once, after the apply
    /// Its workspace draws nothing (`WorkspaceContentController.drawsNothing`): no strip observation runs and
    /// no content is shown; `resume` maps the strip once and shows the selection then (PL-script A2).
    private(set) var isSuspended = false
    /// Its slice of the launch window's build behind the picture showed it, or the build ended (p08-startup-060).
    var launchReleased = false
    var waitsForLaunchEnd = false // the launch held its content; its afterStartup post is on order (PaneSelectionPresenter)
    /// This pane in the visibility tree (p06-scheduler.md B), under its workspace's node: hidden while
    /// suspended. Not ``isVisible``, which is the layout's viewport presence.
    let visibilityNode: VisibilityNode
    /// The selected tab's node, own-visible under ``visibilityNode`` (`selectTabNode`). Held here, so
    /// the cache keeps it while this pane selects the tab (`TabContentCache.node(for:)`).
    private var selectedTabNode: VisibilityNode?
    #if DEBUG
    private(set) var debugSnapshotRuns = 0 // this pane's strip maps (`structure()`), read by tests
    #endif

    /// The strip. `structure()` reads no tab field (a confirm that draws the same applies nothing); `compose` adds `tabItems`.
    struct Snapshot {
        var tabs: [TabModel] // the daemon tabs shown, in order
        var items: [StripTabItem]
        var groups: [TabGroupItem]
        var defaultIndex: Int
        var generation: String?
        var hidesStrip = false // PaneTabBarChoices: only the person's Hide Tab Bar
        var fullWidthTab = false // PaneFullWidthTabs: the strip shows only the selected tab
        /// `pinned-dock-v1`: the pane is in a pinned column (the Home dock): its first tab
        /// shows no close button.
        var keepsFirstTab = false
        /// False in a pinned column that takes no other tab: no new-tab button.
        var takesNewTabs = true
    }

    /// `workspace` is set before the first apply, so the first frame is the settled one.
    init(pane: PaneModel, daemon: DaemonService, layoutPaneID: LayoutPaneID, services: AppServices, state: WindowState,
         workspace: WorkspaceContentController? = nil) {
        self.pane = pane
        self.workspace = workspace
        self.daemon = daemon
        paneKey = pane.id
        self.layoutPaneID = layoutPaneID
        self.services = services
        self.state = state
        isSuspended = workspace?.drawsNothing == true // a pane made in a parked workspace starts suspended
        let own: Visibility = isSuspended ? .hidden : .visible
        // Under its workspace's node (p06-scheduler-023); a pane outside a workspace (tests) is a root.
        let parent: VisibilityNode? = workspace.flatMap { $0.visibilityNode }
        visibilityNode = parent.map { VisibilityNode("pane:\(pane.id)", own: own, parent: $0) }
            ?? VisibilityNode(root: "pane:\(pane.id)", own: own, workCounts: services.visibilityWorkCounts)
        view = PaneContentView(stripModel: stripModel, reveal: services.launchReveal, input: services.inputTap, node: visibilityNode, deadlines: services.mainDeadlines)
        stripModel.intentHandler = { [weak self] intent in self?.handle(intent) }
        view.stripView.previewProvider = services.previews
        view.stripView.hoverFrameInput = services.hoverFrameInput  // hover once per frame (`pointerFrameHover`)
        view.stripView.scrollFrameInput = services.tabScrollFrameInput  // scroll by translation once per frame (`tabStripScrollFrames`)
        view.stripView.setResourceSource(services.resources, deadlines: services.mainDeadlines)
        view.stripView.contextMenuProvider = { [weak self] target in self?.contextMenu(for: target) }
        view.stripView.attachHoverCards(services.hoverCards, memory: services.memoryCoordinator, thumbnailPages: services.cache.imageCaches.pictureAllocator, energy: services.cache.hibernation?.highEnergy) // p07-memory-005, p07-memory-107, p14-energy-125
        view.stripView.onHoverTab = { [weak self] id in self?.noteHover(id) }
        view.stripView.newTabShortcut = { [weak services] in services?.registry.shortcutDisplay(for: StripNewTab.action) }
        view.onResize = { [weak services, weak paneView = view] in
            services?.surfaceInvariant.noteChange()
            services?.newTabSpares.paneLayoutDidChange(in: paneView?.window) // the parked New Tab spare follows
        }
        #if DEBUG
        DebugLayoutCounters.note("pane mount", #fileID, #line)
        #endif
        observe()
    }

    func teardown() {
        observation?.cancel()
        tabItems.cancelAll()
        services.presentation.cancel(self)
        // No-op for a tab that moved to another pane: its new pane owns it.
        services.cache.removePresenter(self)
        services.cache.hibernation?.paneDidGo(ObjectIdentifier(self))
        // Page tabs of panes the live tree no longer lists close now
        // rather than at the store's next observation; a workspace switch or
        // a layout move keeps the pane listed, so its tabs stay.
        services.closeGoneLocalTabs(in: daemon.store)
        currentTabKey = nil
        DebugTabSwitch.forget(self)
        view.dropParked()
        view.detachContent()
        visibilityNode.set(.hidden) // a tab still selected here is hidden; one that moved away is its new pane's
        selectedTabNode = nil
        services.surfaceInvariant.noteChange()
    }

    // MARK: Sync

    func observe() {
        // One snapshot now (the first frame), tracked; the stream brings the later ones. A trigger:
        // `apply` is also called outside the stream (`syncStripFromStore`) and compares with what it applied.
        tabItems.cancelAll() // a new record's tabs are new objects
        guard !isSuspended else { // `resume` starts it: the strip is mapped once, when the workspace draws again
            observation?.cancel(); observation = nil
            return
        }
        let (first, later) = ObservationStream.current({ [weak self] in ObservationTrigger(self?.structure()) })
        observation?.cancel(); observation = Task { [weak self] in
            for await structure in later {
                guard let self, let structure = structure.value else { return }
                // A tab moved in or out of this pane (its record's tabs changed): the workspace's layout and every
                // moved strip change in this turn, under one topology, so focus follows the tab at once.
                if self.stripIsStale {
                    self.workspace?.applyMovedTabs()
                    guard !Task.isCancelled else { return } // that apply removed this pane (teardown cancels this task)
                    if !self.stripIsStale { continue } // it mapped this strip from the store already: no second map
                }
                self.apply(self.compose(structure))
            }
        }
        if let first = first.value { apply(compose(first)) }
    }

    /// The strip now, every tab's item mapped again (for a caller whose change no observation sees).
    func snapshot(_ file: StaticString = #fileID, _ line: UInt = #line) -> Snapshot {
        compose(structure(file, line), refresh: true)
    }

    /// One tab's strip item changed (`tabItems`): apply it with the list as it is now (untracked).
    /// Suspended: `resume` maps the strip anyway.
    private func tabItemChanged() {
        guard !isSuspended else { return }
        apply(compose(structure()))
    }

    /// Its workspace stopped drawing: the strip observation stops (a change marks nothing but the
    /// store; `resume` reads it then) and no content is shown or made.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        if let currentTabKey { services.cache.createTabs.hidden(currentTabKey) } // create.tab: hidden before its frame, no sample
        observation?.cancel(); observation = nil
        tabItems.cancelAll() // a title or busy-dot change in a parked workspace maps no tab item
        services.presentation.cancel(self)
        DebugTabSwitch.forget(self) // a switch whose content never showed is not timed across the hidden time
        visibilityNode.set(.hidden)
    }

    /// Its workspace draws again: one strip map (the observation starts over, tracked), whose apply
    /// shows the selection as it is now, with no page or surface made for a selection it passed.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        observe()
        // After the strip map: its selection changes flipped no tab, so only the tab selected now flips.
        visibilityNode.set(.visible)
    }

    /// The strip lags the pane record's tabs (a tab moved out or in since its last apply).
    var stripIsStale: Bool { !isSuspended && !pane.tabs.lazy.map(\.id).elementsEqual(appliedRecordTabs) }

    /// Maps the strip again when it lags the record (`stripIsStale`), as its observation would.
    func syncStripIfStale() {
        guard stripIsStale else { return }
        apply(compose(structure()))
    }

    private func compose(_ structure: Snapshot, refresh: Bool = false) -> Snapshot {
        var result = structure
        result.items = tabItems.items(for: structure.tabs, id: \TabModel.id, refresh: refresh).map { $0.0 } + structure.items
        if structure.keepsFirstTab, !structure.tabs.isEmpty { result.items[0].isClosable = false }
        return result
    }

    /// The tabs the strip leaves out: a dock-bound chat (`dockBound`) or a tab on its way to the side (`OutboundTab`).
    var stripHidden: Set<String> { dockBound.union(OutboundTab.hidden(in: self)) }

    func structure(_ file: StaticString = #fileID, _ line: UInt = #line) -> Snapshot {
        #if DEBUG
        DebugLayoutCounters.paneSnapshots &+= 1
        debugSnapshotRuns += 1
        DebugLayoutCounters.note(debugSnapshotRuns > 3 ? "snapshot later" : "snapshot #\(debugSnapshotRuns)", file, line) // a new pane's runs, else another pane's
        #endif
        let store = daemon.store
        // This pane's own workspace record: reading its fields observes them
        // only, never the workspace list (a lookup by pane would).
        let ownWorkspace = workspace?.workspace ?? store.workspace(containing: pane.handle)
        let hidden = stripHidden
        var local: [StripTabItem] = []
        for tab in state?.localBrowserTabs[paneKey] ?? [] where !hidden.contains(tab.id) {
            let page = services.cache.existingBrowser(tab.id)?.tab.state
            let title = page?.title.flatMap { $0.isEmpty ? nil : $0 } ?? page?.url?.host() ?? Strings.untitledBrowser
            var item = StripTabItem(id: StripTabID(tab.id), title: title, subtitle: page?.url?.absoluteString,
                                    icon: .icon(.browser))
            item.isDormant = services.cache.dormantTabs.contains(tab.id)
            browserIcon(key: tab.id, recordFavicon: nil).apply(to: &item)
            local.append(item)
        }
        local += services.localTabItems(in: paneKey, hiding: hidden)
        let groupAsset = IconAssetImages.shared.tabIcon(owner: daemon)
        let groups = pane.tabGroups.map { group in
            TabItemMapping.shared.groupItem(group, isSaved: group.isSaved, asset: groupAsset)
        }
        // The column kind decides (`pinned-dock-v1`), never the tab's title or page.
        let dock = ownWorkspace?.screens.lazy.flatMap(\.columns).first { $0.layout.paneIDs.contains(pane.handle) }?.dock
        let pinned = dock?.isPinned == true
        let tabs = pane.tabs.filter { !hidden.contains($0.id) }
        // The Home Chief pane (a pinned dock) shows no tab bar while it holds only Home (Lawrence
        // 2026-10-23: "home chief should have no tabbar"); a tab dragged in brings it back while it
        // is there (plans/cmux-next/home-chief-pane.md H1).
        let homeChief = dock.map { LayoutMapping.dock($0).hidesTabBar(shownTabs: tabs.count + local.count) } ?? false
        return Snapshot(tabs: tabs, items: local, groups: groups,
                         defaultIndex: pane.defaultTabIndex, generation: store.generation?.rawValue,
                         // An app workspace's one pane shows its app without a strip (`app-screens-v1`).
                         hidesStrip: hidesTabBar || ownWorkspace?.app != nil || homeChief,
                         fullWidthTab: services.paneFullWidthTabs.contains(paneKey),
                         keepsFirstTab: pinned && tabs.first?.id == pane.tabs.first?.id,
                         // What Home's pinned dock opens goes beside it (ChatColumnPlacement, and
                         // LinkOpener for links), so its strip has no +.
                         takesNewTabs: !pinned)
    }

    /// Daemon tab `tab`'s strip item; observed one tab at a time (`tabItems`).
    private func tabItem(_ tab: TabModel) -> StripTabItem {
        let fallback = Strings.untitledTerminal
        // Terminals on another machine carry its name; browsers always run here.
        let machine = daemon.isLocal ? nil : services.machines.tabBadge(daemon.machineID)
        let ownWorkspace = workspace?.workspace ?? daemon.store.workspace(containing: pane.handle)
        // The one title rule (`TabTitleResolver`), shared with the sidebar and the closed-tab toasts.
        var titles = TabTitleResolver(services: services, workspace: ownWorkspace?.handle)
        if tab.agentSession != nil { titles.workspaceName = AgentChatTabTitle.workspaceName(ownWorkspace) }
        // A new tab page is "New Tab", with the new-tab icon, until it
        // becomes a chat (then the chat's title and icon).
        let isNewTabPage = titles.isNewTabPage(tab)
        var item = TabItemMapping.shared.item(tab, fallbackTitle: titles.untitled(tab, fallback: fallback), isNewTabPage: isNewTabPage, restarting: daemon.restartsKeptTab(tab))
        // Reading the app's provider here (the apps mirror) re-runs the snapshot, and so the
        // content, when the app becomes available after the tree arrived.
        // An app or page tab names and badges itself like the page it shows.
        if let page = titles.page(tab) {
            item.title = page.title
            item.icon = page.icon
        }
        // A Home tab dots while any Home conversation is unread, as the sidebar's Home item counts them.
        if HomeService.isHomeTab(page: tab.page, app: tab.appTab?.app), !services.home.unreadConversations.isEmpty { item.isUnread = true }
        item.groupID = tab.tabGroup.map { TabGroupID($0.rawValue) }
        if !DesignSettings.shared.attention.showsOnTab { item.isUnread = false }
        item.isDormant = services.cache.dormantTabs.contains(tab.id)
        if tab.kind == .remoteTerminal {
            // Its terminal runs on another machine: that machine's name.
            (item.machineBadge, item.machineName) = RemoteTerminalService.badge(for: tab, machines: services.machines)
            item.icon = .icon(.terminal)
        } else if tab.kind != .browser {
            (item.machineBadge, item.machineName) = (machine, machine.flatMap { _ in services.machines.machineName(daemon.machineID) })
            item.themeBadge = services.themes.badge(forTerminal: TerminalThemeKey(machine: daemon.machineID, tab: tab))
        } else {
            // A browser tab names the machine whose localhost it sees.
            let engine: BrowserEngineKind = tab.browserEngine == BrowserEngineTag.cef.rawValue ? .cef : .webkit
            let badge = tab.url.flatMap(URL.init(string:)).flatMap { services.machines.mayHaveLocalhostBadge($0, daemon: daemon) ? services.remoteLocalhost.badge(for: tab, url: $0, engine: engine) : nil }
            (item.machineBadge, item.machineBadgeHelp, item.machineName) = (badge?.text, badge?.help, services.machines.tabColorName(daemon.machineID, badge: badge?.text))
            // Incognito tabs have only a placeholder record in the daemon.
            let incognito = services.cache.browserTabs.isIncognitoTab(tab.id)
            if incognito {
                let live = services.cache.incognitoDisplay(tab)
                (item.title, item.subtitle) = (live.title ?? Strings.untitledBrowser, live.url.flatMap { BrowserNewTabPage.isNewTabPage($0) ? nil : $0 })
            } else {
                // The room's browser profile, not the room: a room switch wakes no tab item (space-switch-fast).
                item.profileBadge = state.map { services.browserProfiles.tabBadge(for: tab, workspaceID: ownWorkspace?.id, roomBrowserProfile: $0.roomBrowserProfileID) }
                    ?? services.browserProfiles.tabBadge(for: tab, workspaceID: ownWorkspace?.id, room: nil)
                if services.cache.pageRequests.titleAttention.marks(tab, selected: stripSelection == tab.id, in: services.cache) { item.isUnread = true }
            }
            browserIcon(key: tab.id, recordFavicon: incognito ? nil : tab.faviconURL, recordURL: tab.url).apply(to: &item)
            item.audio = BrowserTabAudio.badge(services.cache.existingBrowser(tab.id)?.tab.state)
        }
        TabItemMapping.shared.applyUserIcon(tab, to: &item, asset: IconAssetImages.shared.tabIcon(owner: daemon))
        return item
    }

    /// The page icon, favicon, throbber or globe of browser tab `key`: its live page's
    /// address, load state and favicon, else the address and favicon its record names.
    private func browserIcon(key: String, recordFavicon: String?, recordURL: String? = nil) -> BrowserTabIconState {
        let page = services.cache.existingBrowser(key)?.tab.state
        let image = services.browserFavicon(key: key, recordFavicon: recordFavicon)
        let url = page?.url ?? recordURL.flatMap(URL.init(string:))
        return .resolve(isLoading: page?.isLoading ?? false, isDormant: services.cache.dormantTabs.contains(key), favicon: image, url: url, isWaiting: page?.isWaiting ?? false)
    }

    /// Pushes daemon truth (a New Tab page's replacement in its slot: NewTabSuccession) into the strip. `force` resets optimistic strip state after a rejected command.
    func apply(_ reported: Snapshot, force: Bool = false) {
        let snapshot = NewTabSuccession.order(reported, in: self)
        appliedRecordTabs = pane.tabs.map(\.id)
        if force { view.stripView.discardPendingReorder() }
        if view.hidesStrip != snapshot.hidesStrip { view.hidesStrip = snapshot.hidesStrip }
        if stripModel.showsSelectedFullWidth != snapshot.fullWidthTab { stripModel.showsSelectedFullWidth = snapshot.fullWidthTab }
        if stripModel.groups != snapshot.groups { stripModel.groups = snapshot.groups }
        if stripModel.tabs != snapshot.items {
            stripModel.tabs = snapshot.items
            noteNeighbors()  // a reorder, close or new tab moves the neighbors
        }
        if stripModel.showsNewTabButton != snapshot.takesNewTabs { stripModel.showsNewTabButton = snapshot.takesNewTabs }
        if !snapshot.items.isEmpty { services.launchReveal.markReady(.tabs) }
        var selectNew = false
        if let pending = pendingSelectSurface, let tab = snapshot.tabs.first(where: { $0.surface == pending }) { // once listed (OutboundTab)
            if !isSuspended { NewTerminalTrace.shared.event(.tabAdded, of: services.cache.createTabs.listed(surface: pending.rawValue, tab: tab.id), value: pending.rawValue) } // create.tab waits for its frame; a new terminal marks tab_added
            state?.selection.select(tab.id, in: paneKey)
            pendingSelectSurface = nil
            selectNew = true
        } else if let pending = pendingSelectTab, let tab = pane.tabs.first(where: { $0.id == pending }) {
            state?.selection.select(tab.id, in: paneKey)
            pendingSelectTab = nil
            selectNew = true
        }
        // Members of a collapsed group are hidden: a closed selected tab's successor skips them while a shown tab survives (close-focus.md).
        let collapsed = Set(snapshot.groups.filter(\.isCollapsed).map(\.id))
        let hidden = Set(snapshot.items.filter { $0.groupID.map(collapsed.contains) ?? false }.map(\.id.rawValue))
        let selected = state?.selection.resolve(pane: paneKey, tabs: snapshot.items.map(\.id.rawValue), defaultIndex: snapshot.defaultIndex, hidden: hidden,
                                                openers: services.cache.pageRequests.openers.closeRelations(among: pane.tabs, last: &closeTabs))
        setStripSelection(selected.map { StripTabID($0) })
        let selectedID = stripModel.selectedID
        if selectNew {
            // A tab this window created: show it now (focus is the
            // coordinator's expectation, not decided here).
            showSelectionNow()
        } else if let selectedID, selectedID.rawValue != currentTabKey {
            presentSelection() // a close selected the neighbor
        } else {
            // Model-driven: show on the next frame, coalescing transient selections.
            services.presentation.setNeedsShowSelected(self)
        }
        // Focus follows selection; the coordinator re-targets the keyboard
        // (only when this pane's tabs or selection changed).
        sendTopologyIfChanged()
        dropClosedParked(snapshot)
        remapViewedTab()
    }

    /// Maps the strip again for a tab whose attention dot went (`setStripSelection`), once.
    func remapViewedTab() {
        guard remapsViewedTab, !isSuspended else { return }
        remapsViewedTab = false
        syncStripFromStore()
    }

    /// Selects `id` on the strip; a newly selected tab is viewed (its title attention dot goes).
    func setStripSelection(_ id: StripTabID?) {
        if stripModel.selectedID != id { stripModel.selectedID = id }
        selectTabNode(id?.rawValue)
        guard stripSelection != id?.rawValue else { return }
        stripSelection = id?.rawValue
        if let key = id?.rawValue, services.cache.pageRequests.titleAttention.viewed(key) { remapsViewedTab = true }
    }

    /// A tab is visible when it is selected in a visible pane (p06-scheduler.md B): in the selection's
    /// turn, the selected tab's node goes own-visible under this pane's node and the one it replaces
    /// own-hidden, as Chromium's `BrowserView::OnActiveTabChanged` (chrome/browser/ui/views/frame/browser_view.cc)
    /// hides the old WebContents and shows the new one in one task. A tab that another pane selected
    /// since (it moved there) belongs to that pane: it is not hidden from here.
    private func selectTabNode(_ key: String?) {
        let next = key.map { services.cache.node(for: $0) }
        if let shown = selectedTabNode, shown !== next, shown.parent === visibilityNode { shown.set(.hidden) }
        selectedTabNode = next
        guard let next else { return }
        // A no-op when it is already here. It cannot throw: a tab's node is a child (`TabContentCache.node(for:)`)
        // and a pane's node is never below a tab's.
        try? next.attach(to: visibilityNode)
        next.set(.visible)
    }

    /// Marks the workspace's focus topology changed when this pane's part of it changed: the
    /// workspace sends one for all panes that change in this turn (`setNeedsTopology`).
    func sendTopologyIfChanged() {
        let current = focusPane
        guard current != sentFocusPane else { return }
        sentFocusPane = current
        workspace?.setNeedsTopology()
    }

    /// Content parked in this pane (`PaneContentView+Parking`) whose tab closed, moved away or
    /// got a new view leaves the window. Live views come from `existingContent(for:)`, the one
    /// lookup of every content kind, so a kind that parks (a page tab) is never dropped as closed.
    private func dropClosedParked(_ snapshot: Snapshot) {
        guard !view.parked.isEmpty else { return }
        let live = Set(snapshot.items.compactMap { existingContent(for: $0.id.rawValue)?.view }.map(ObjectIdentifier.init))
        view.prunePark { live.contains(ObjectIdentifier($0)) }
    }

    /// Selects the tab on `surface`, which this app just created here, once
    /// the daemon reports it, and shows it now when it already does. An
    /// action run without view-change permission (a CLI, script or agent
    /// run without `focus: true`) creates the tab in the background.
    func selectWhenReported(surface: SurfaceID) {
        guard ActionRunScope.viewChangeAllowed() else { services.cache.createTabs.dropped(surface: surface.rawValue); return apply(snapshot()) } // a background create: no create.tab sample
        pendingSelectSurface = surface
        apply(snapshot())
    }

    /// Same, for a tab named by its resource id (a reopened tab).
    func selectWhenReported(tab: String) {
        guard ActionRunScope.viewChangeAllowed() else { return apply(snapshot()) }
        pendingSelectTab = tab
        apply(snapshot())
    }

    /// Re-pushes daemon truth after a rejection.
    func resyncStrip() {
        apply(snapshot(), force: true)
    }

    /// Pushes the store's current tabs into the strip now (no reset of
    /// optimistic strip state), ahead of the next observation step.
    func syncStripFromStore() {
        apply(snapshot())
    }

    // MARK: Content

    /// Shows the selection now, also while the launch holds this pane (``showSelected()`` is the held path):
    /// for an action that needs the tab's live content, a CLI, socket or agent target or a tab this window created.
    func showSelectionNow() {
        guard !isSuspended else { return } // `resume`'s apply shows the selection then
        let key = stripModel.selectedID?.rawValue, previous = currentTabKey, buildsAtLaunch = buildsContentAtLaunch
        if key != currentTabKey {
            InputJournal.shared.append(window: state?.id, .content(tab: key ?? "-", event: "show pane=\(paneKey) from=\(currentTabKey ?? "-")"))
            // Another tab's last page from the launch must not stay under this one.
            view.clearLaunchImage(.noVisiblePane)
        }
        if let currentTabKey, currentTabKey != key { BenchSpans.measure("switch.withdraw") { services.cache.withdraw(currentTabKey, by: self) } }
        DebugTabSwitch.mark(self, "withdraw")
        // May replace a stale surface, displacing the view shown here.
        let content = BenchSpans.measure("switch.content") { key.flatMap(content(for:)) }
        if buildsAtLaunch, content != nil { services.launchPanes.noteBuilt() }
        DebugTabSwitch.mark(self, "content")
        if let content, let key { DebugTabSwitch.content(self, content, key: key) }
        // The tab's node is the one `selectTabNode` made visible; a no-op when the content follows it already.
        if let content, let key { content.followAppearance(services.appearance, node: services.cache.node(for: key)) }
        if let content, let key { content.followVisibility(services.cache.node(for: key), services: services) }
        currentTabKey = key
        services.themes.applyPaneBackground(self) // a tab's own tint (no work while nothing is set)
        if let key, content != nil { BenchSpans.measure("switch.present") { services.cache.present(key, by: self, presence: presence) } }
        DebugTabSwitch.mark(self, "reveal")
        if view.stripView.window != nil { BenchSpans.measure("switch.strip") { view.stripView.syncFromModel() } } // strip + content: one transaction (L4)
        DebugTabSwitch.mark(self, "stripSync")
        BenchSpans.measure("switch.view") { _ = view.show(content?.view) }
        // A browser tab (its page made or not yet) shows its page's picture from the last quit over it (p08-startup-043).
        switch content {
        case .browser?, nil: if let key { services.cache.showLaunchPicture(key, in: view, hold: services.launchImageHold, reveal: services.launchReveal) }
        default: break
        }
        DebugTabSwitch.contentShown(self, key: key)
        if services.cache.createTabs.isWaiting { services.cache.createTabs.switched(from: previous, to: key, firstFrame: content?.createTabFirstFrame) } // create.tab: one hidden first ends unsampled
        // Terminals come in on their first frame (`LaunchSettle`), or at once with their frame from the last
        // quit (`TerminalLaunchFrames`); other content (a page, an agent) is ready once shown, and a page's
        // first paint while shown is the launch's `first_page_frame`.
        if case .terminal(let terminal) = content, let key { if services.terminalLaunchFrames.show(key, on: terminal.session, in: view.contentHost, reveal: services.launchReveal) { DebugTimings.markLaunch("terminal.launch_frame_shown") } } else if let content { services.launchReveal.markReady(.pane); if let key { DebugTimings.markFirstPageFrame(of: content.view, node: services.cache.node(for: key)) } }
        // The content view exists now: the coordinator re-applies focus if
        // this pane has it (content is shown a frame after selection).
        if workspace?.isParked == false { BenchSpans.measure("switch.focus") { workspace?.focus.send(.contentPresented(pane: paneKey)) } }
        BenchSpans.measure("switch.invariant") { services.surfaceInvariant.noteChange() }
        BenchSpans.measure("switch.neighbors") { noteNeighbors() }
    }

    /// Another pane took `key`'s view (the tab moved there) or its surface
    /// was destroyed. Let the view go without pausing it; re-present when
    /// this pane shows the tab again.
    func surfaceWasDisplaced(_ key: String) { letGo(key, parks: false) }
    func letGo(_ key: String, parks: Bool) {
        guard currentTabKey == key else { return }
        currentTabKey = nil
        view.detachContent(parks: parks)
        services.surfaceInvariant.noteChange()
    }

    /// The selected tab is a terminal that will draw a frame (not a dead one).
    var showsLiveTerminal: Bool {
        guard let key = stripModel.selectedID?.rawValue, let tab = pane.tabs.first(where: { $0.id == key }) else { return false }
        return tab.kind == .pty && !tab.dead
    }

    /// The Chromium window this pane's page tabs share (p13-webui-063); nil while the pane is in no window.
    var pageChromiumWindow: PageChromiumWindow? {
        state.map { PageChromiumWindow(window: $0.id, pane: paneKey) }
    }

    /// This pane is its workspace's focused pane.
    var isFocusedInWorkspace: Bool {
        workspace?.focus.state.pane == paneKey
    }

    func content(for key: String) -> TabContent? {
        if key.hasPrefix(LocalPageTab.prefix) { return services.pages.view(for: key, in: pageChromiumWindow).map(TabContent.page) }
        if key.hasPrefix(LocalBrowserTab.prefix) {
            let local = state?.localBrowserTabs[paneKey].first { $0.id == key }
            // A local tab of an incognito window uses its off-the-record profile.
            let incognito = state.map { services.windows.isIncognito(window: $0.id) } == true
            let profile = incognito ? services.windows.incognitoProfile() : nil
            return .browser(services.cache.browser(for: key, url: local?.url, profile: profile))
        }
        guard let tab = pane.tabs.first(where: { $0.id == key }) else { return nil }
        switch tab.kind {
        case .pty: return TerminalTabContent.make(tab, in: self)
        case .browser where tab.appTab != nil: return appTabContent(tab)
        case .browser where tab.isFrontendOwned:
            return services.cache.browser(for: tab).map(TabContent.browser)
        case .remoteTerminal:
            return services.remoteTerminals.content(for: tab, home: daemon)
        case .conversation where tab.agentSession != nil: return AgentTabContent(pane: self).content(key)
        case .conversation where tab.page != nil:
            return services.pages.view(forStoreTab: tab, in: daemon.store, local: daemon.isLocal,
                                       window: state.flatMap { services.windows.controller(for: $0.id) }, pane: pageChromiumWindow)
                .map(TabContent.page)
        case .conversation: return services.home.tabView(for: tab).map(TabContent.conversation)
        default:
            return nil
        }
    }

    /// The shown tab's live content. Never creates a surface.
    var currentContent: TabContent? { currentTabKey.flatMap(existingContent(for:)) }

    /// `key`'s live content, if its surface or page exists.
    func existingContent(for key: String) -> TabContent? {
        if let entry = services.cache.existingTerminal(key) { return .terminal(entry) }
        if let view = services.agentTabs.existingView(key) { return .agent(view) }
        if let notice = services.agentTabs.notices[services.agentTabs.resolve(key)] { return .notice(notice) }
        if let view = services.pages.existingView(key) { return .page(view) }
        if let placeholder = services.madeRemoteTerminals?.existingPlaceholder(key) { return .placeholder(placeholder) }
        if let home = services.home.existingTabView(key) { return .conversation(home) }
        return services.cache.existingBrowser(key).map(TabContent.browser)
    }

    /// The layout reported this pane on screen, in the keep-alive band, or away.
    func setPresence(_ presence: SurfacePresence) {
        guard self.presence != presence else { return }
        self.presence = presence
        services.cache.setPresence(presence, presenter: self)
        noteNeighbors()
        guard !isSuspended else { return services.surfaceInvariant.noteChange() }
        // Content destroyed while away re-attaches (daemon replay) as soon as
        // the pane nears the viewport, so it is ready before it scrolls in.
        if presence != .hidden, stripModel.selectedID != nil, currentTabKey == nil || !view.hostsContent {
            // On screen: show now (a split's new pane draws with the layout
            // change, no blank frame), within the one-surface-per-frame budget; at launch the focused pane first.
            if presence == .visible, !showsAfterFocusedAtLaunch {
                services.presentation.showNow(self)
            } else {
                services.presentation.setNeedsShowSelected(self)
            }
        }
        services.surfaceInvariant.noteChange()
    }

    /// Focuses this pane's selected content through the window's focus
    /// coordinator (the only writer of focus).
    func focusContent(source: FocusEvent.Source = .intent) {
        workspace?.focus.send(.focusPane(paneKey, source: source))
    }

    // MARK: Lookup

    func tab(_ id: StripTabID) -> TabModel? { pane.tabs.first { $0.id == id.rawValue } }

    var selectedTab: TabModel? { stripModel.selectedID.flatMap(tab) }

    var orderedIDs: [StripTabID] { stripModel.orderedTabs.map(\.id) }
}

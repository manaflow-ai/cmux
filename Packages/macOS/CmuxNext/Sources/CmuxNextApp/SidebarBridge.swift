import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextBridge
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar
import Observation

/// Feeds one window's sidebar from the daemon store and turns sidebar
/// intents into daemon commands (SidebarBridge+Intents). Selection is
/// client-local: it only changes which workspace this window shows.
final class SidebarBridge {
    let model = SidebarCollapsedSections(defaults: .standard).restoring(SidebarModel())
    let container: SidebarContainerView
    unowned let services: AppServices
    /// Weak: a daemon command's `Task` can outlive the window.
    weak var state: WindowState?
    /// The rows and selection observations, also run in the turn the window shows a workspace.
    private(set) lazy var sameTurn = SidebarSameTurn(view: container.sidebarView)
    private var widthObservation: Task<Void, Never>?
    /// Item presentation for sidebar sections (SidebarBridge+Sections).
    var sectionsObservation: Task<Void, Never>?
    /// The window's app sections (no All chats: it is on the New Tab page, cx-n0i9).
    private var appSections: SidebarAppSections?
    var cardsObservation: Task<Void, Never>?
    /// True once the sidebar shows real content: saved rows, the first
    /// live rows, or a settled empty or unavailable state, which marks the
    /// sidebar region ready for `LaunchReveal`.
    private(set) var isReadyForReveal = false
    /// The window's saved rows, shown until live data replaces them.
    private var seed = SidebarSeed()
    /// The one writer of the rows: live rows plus pending edits (cx-odqn).
    lazy var rows = SidebarRows(model: model)
    lazy var selectionHold = SidebarSelectionHold(model: model)
    /// The saved space bar, shown until the local daemon reports its spaces.
    private var seededProfiles: (profiles: [SidebarProfile], active: SidebarProfileKey?)?
    /// Saves what the sidebar shows (`SidebarSnapshotStore`).
    private var snapshotRecorder = SidebarSnapshotRecorder()
    /// Organization intents waiting for the home session's personal state.
    let organizationQueue = SidebarOrganizationQueue()
    /// Group name editors waiting for their group, and groups made empty (cx-rcby).
    let groupEditor = PersonalGroupEditorState()
    /// Rows of the spaces beside the current one, for swipe pages (R99).
    let spaceCache = SpaceSectionsCache()
    /// Each listed row's content, observed per row: a status change patches one row, not the sidebar (rows lane).
    /// Its flushes run on the display frame, so a frame's row patches and its scroll update commit together.
    let rowFeed: SidebarRowFeed = {
        let frames = FrameBatcher(owner: "SidebarRows")
        return SidebarRowFeed(schedule: { work in frames.scheduleFrame(work) })
    }()

    init(services: AppServices, state: WindowState) {
        self.services = services
        self.state = state
        container = SidebarContainerView(model: model)
        model.onIntent = { [weak self] intent in self?.handle(intent) }
        // Loose rows come before every group unless the home session places
        // groups among them (`personal-mixed-order-v1`); refreshed on show.
        model.ungroupedFirst = !services.machines.local.store.supportsPersonalMixedOrder
        // Synchronous, before the hide animation starts: focus leaves the
        // sidebar in the same turn (plans/cmux-next/focus.md).
        model.onPresentationChange = { [weak state] presentation in
            state?.focus.send(.sidebarVisibility(hidden: presentation == .hidden))
        }
        container.sidebarView.contextMenuProvider = { [weak self] target in self?.contextMenu(for: target) }
        groupFlow.wireEditor()
        SidebarWorkspacePins.wire(self)
        // The Chief dropped beside the sidebar comes off it, as Remove from Sidebar does (Leo 2026-10-21), in a band,
        // a group or a machine list.
        container.sidebarView.removesOnDragOut = { [weak model] id in
            (model?.layout.item(LayoutItemID(id)) ?? model?.listedItem(LayoutItemID(id)))?.ref == .builtIn(.chief)
        }
        container.sidebarView.onDragOutRemove = { [weak services] id in
            _ = services?.registry.perform("sidebar.item.removeEverywhere", invocation: ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: id), origin: .user))
        }
        // The row the person is likely to open next: the agent chat on screen reads its chat ahead (HQ#5914), this Mac's chats only.
        container.sidebarView.onHoverTab = { [weak self] tab in
            guard let self, let window = self.state, let shown = self.services.windows.controller(for: window.id)?.focusedPane?.stripModel.selectedID else { return }
            let tabs = self.services.agentTabs
            tabs.existingView(shown.rawValue)?.forwardHover(tab.flatMap { tabs.existingView($0.rawValue) == nil && tabs.daemonForTab($0.rawValue)?.isLocal == true ? tabs.session(of: $0.rawValue) : nil })
        }
        container.sidebarView.resourceSource = services.resources
        container.sidebarView.hoverCards = services.hoverCards
        container.sidebarView.customization = services.sidebarCustomization
        // The workspace card's history (u3320), read from the workspace's daemon and the acpmux
        // mirror when a card opens.
        let timelines = WorkspaceTimelineReader(turns: AgentTurnStateStore.shared)
        container.sidebarView.timelineSource = { [weak services] id, limit in
            guard let found = services?.machines.workspace(id: id.rawValue) else { return [] }
            return timelines.entries(found.0, agents: found.1.store.agents, limit: limit)
        }
        // The React update surfaces: the staged card's highlights popover and the Updated card (cx-urd.61.2).
        container.sidebarView.updateSurfaces = UpdateSurfaceIslands(services: services)
        appSections?.releaseAll()
        let sections = SidebarAppSections(apps: services.apps)
        appSections = sections
        container.sidebarView.appSections = sections
        // Return or Escape in the inline rename field gives the keyboard
        // back to the focused content (plans/cmux-next/focus.md R8).
        container.sidebarView.onRenameEnded = { [weak state] byKeyboard in
            guard byKeyboard, let focus = state?.focus else { return }
            focus.send(.focusTarget(.content, source: .keyboard))
        }
        seedFromSnapshot(state)
        // Clear until real content (`markReadyForReveal`, or the deadline); a no-op once it is ready.
        services.launchReveal.hold(container, until: .sidebar)
        observe()
        observeSections()
        observeCards()
    }

    func teardown() {
        sameTurn.cancel()
        rowFeed.reset()
        widthObservation?.cancel()
        sectionsObservation?.cancel()
        appSections?.releaseAll()
        cardsObservation?.cancel()
        // The update surface pages cancel their subscriptions (cx-urd.61.2).
        container.sidebarView.updateSurfaces = nil
    }

    private func observe() {
        let machines = services.machines
        let registry = services.windows.registry
        let layout = services.sidebarLayout
        let agentTabs = services.agentTabs
        let notifications = services.notifications
        let creations = services.cloud.creations
        let services = services
        guard let windowState = state else { return }
        // Decorations go on after the feed: the pass names rows by stub (no title yet), and a patched row is undecorated.
        let feed = rowFeed, customization = services.sidebarCustomization
        feed.onChange = { [weak self] changed in
            let decorations = customization.rowDecorations
            self?.rows.patch(changed.map { $0.decorated(by: decorations) })
        }
        // `state.id` is read inside: the launch window adopts a saved id.
        // The layout too: removing the Home item lists the home workspace.
        // And the New Tab pages (a chat lists as a chat) and the muted set.
        // The spaces and the current space come from the same observation
        // as the rows (cx-5k3r): a space switch reaches the sidebar as one
        // change (new space and its rows together), so the sidebar runs
        // one slide, not a slide of the old rows and then a row reload.
        // The band's layout comes with the rows it projects too (cx-odqn):
        // a pinned workspace leaves the list in the turn it joins the band.
        sameTurn.observe(listsRows: true, {
            // Rows come from the feed: this pass reads no row's status; a row reads its tab selection itself.
            let pages = Self.newTabPages(agentTabs, in: machines.local.store), muted = notifications.preferences.mutedWorkspaces
            feed.beginPass(inputs: [pages, muted, DesignSettings.shared.attention.showsOnSidebar] as [AnyHashable])
            let (listed, launching, failed) = Self.liveSections(
                machines, registry: registry, window: windowState, creations: creations, hidesHome: Self.hidesHome(layout.document),
                newTabPages: pages, muted: muted,
                top: .make(layout, machines: machines, room: windowState.profileID.rawValue), pageFace: services.sidebarPageFace,
                tabTitle: Self.tabTitle(services), rows: feed.laneRowSource,
                groupConfig: services.settings?.snapshot.workspaceGroups ?? WorkspaceGroupConfig(),
                harnessIcons: { [weak services] in services?.harnessIconLookup ?? .none })
            // Not the creates' rows (PendingWorkspaceRows): they draw from the press (its redraws below), and a walk reads them as it shows.
            // The document projection these rows were built from (`SidebarRows.layoutCatchingUp`).
            return ((PendingWorkspaceRows.shared.listing(listed, in: windowState.id, machines: machines), services.sidebarCustomization.rowDecorations,
                     SidebarDocStore.current?.shownChanges), launching, failed, SidebarSpaceBar.profiles(machines.local, window: windowState.id, windows: services.windows), SidebarProfileKey(windowState.profileID.rawValue),
                    SidebarRows.visibleLayout(services, window: windowState))
        }) { [weak self] value in
            let ((sections, decorations, shownAt), launching, failed, profiles, active, shown) = value
            guard let self else { return }
            self.showProfiles(profiles, active: active, launching: launching)
            self.show(SidebarSection.decorated(feed.fill(sections), decorations), shownAt: shownAt, layout: shown, launching: launching, failed: failed,
                      creating: PendingWorkspaceRows.shared.rows(in: windowState.id))
            services.windows.retryDeferredPlacements() // before pending stand-ins are forgotten
            // A workspace the window lists shows its own row from here on (cx-9a7wx). No create waits: no walk of every row.
            guard !PendingWorkspaceRows.shared.rows.isEmpty else { return }
            PendingWorkspaceRows.shared.forget(in: windowState.id, listed: Set(sections.flatMap(\.workspaces).map(\.id.rawValue)),
                                               held: { machines.workspace(id: $0) != nil }) { id in
                if let owner = registry.value.owner(of: id), owner != windowState.id { return true }
                guard let workspace = WindowProfiles.qualified(id, machines: machines),
                      let pin = WindowProfiles.membership(machines)?.pinned(workspace) else { return false }
                return pin != windowState.profileID
            }
        }
        PendingWorkspaceRows.shared.redraws.add(self) { [weak self] in
            guard let self, let id = self.state?.id else { return }
            rows.show(creating: (PendingWorkspaceRows.shared.rows(in: id), NewWorkspacePlacements.home(services.machines)))
            self.selectionHold.flush() // a selection waiting on the new row takes it in this turn, as `show` does
            container.sidebarView.renderNow() // in this turn, so its frame draws the row
        }
        // R99: the rows of another space, for the page beside the current one during a swipe.
        model.spaceSections = { [weak windowState, spaceCache] key in
            guard let windowState else { return [] }
            return spaceCache.sections(for: key) {
                Self.sections(machines, members: registry.members(of: windowState.id), profile: ProfileID(rawValue: key.rawValue),
                              hidesHome: Self.hidesHome(layout.document), selection: windowState.selection,
                              newTabPages: Self.newTabPages(agentTabs, in: machines.local.store), muted: notifications.preferences.mutedWorkspaces,
                              top: SidebarTopProjection.make(layout, machines: machines, room: key.rawValue), pageFace: services.sidebarPageFace,
                              tabTitle: Self.tabTitle(services), harnessIcons: { [weak services] in services?.harnessIconLookup ?? .none })
            }
        }
        let state = windowState, model = model
        widthObservation = Task { [weak self] in
            for await (width, presentation) in ObservationStream({ (model.width, model.presentation) }) {
                guard let self else { return }
                state.sidebarWidth = Double(width)
                state.sidebarHidden = presentation == .hidden
                self.services.windows.recordSaver.stateDidChange(state)
            }
        }
        // One selection: the shown page's top item, else the shown workspace.
        sameTurn.observe({ SidebarNavigation.selectedItem(page: state.page, workspace: state.workspaceID,
                                                          creationRow: state.cloudCreation.flatMap { creations.creation($0)?.rowID },
                                                          layout: SidebarRows.visibleLayout(layout.document, showAppStore: services.settings?.snapshot.previewFeatures == true), room: state.profileID.rawValue,
                                                          refs: WorkspaceLayoutRefs(machines: machines), home: services.home.dockedHomeID(in: state),
                                                          channels: services.home.dockShowsChannels) }) { [weak self] selected in
            self?.selectionHold.offer(selected) // a new workspace's waits for its row (cx-8g3sn)
        }
    }

    // MARK: Snapshot-first launch

    /// Draws the window's saved sidebar (`SidebarSnapshotStore`) before the
    /// window is presented, so its first frame has rows: its own saved
    /// rows, or for the window a launch opens before it knows the saved
    /// window ids, the most recently used window's. Loading sections with
    /// nothing saved show placeholder rows.
    private func seedFromSnapshot(_ state: WindowState) {
        let windows = services.windows
        let isLaunchWindow = windows.controllers.isEmpty && windows.registry.isLaunching
        let saved = services.sidebarSnapshots.launchDocument.snapshot(for: state.id, fallback: isLaunchWindow)
        seed = SidebarSeed(sections: saved?.sidebarSections ?? [], grace: seed.grace.rerunning(sameTurn), connecting: seed.connecting.rerunning(sameTurn))
        // Collapsed sections: this window's view state, saved only in its sidebar snapshot.
        model.collapsedSections = Set((saved?.sidebarSections ?? []).filter(\.isCollapsed).map(\.id))
        if let saved, !saved.profiles.isEmpty {
            seededProfiles = (saved.sidebarProfiles, saved.sidebarActiveProfileID)
            model.profiles = saved.sidebarProfiles
            model.activeProfileID = saved.sidebarActiveProfileID
        }
        let shownAt = SidebarDocStore.current?.shownChanges
        let (sections, launching, failed) = Self.liveSections(services.machines, registry: windows.registry, window: state, creations: services.cloud.creations,
                                                              hidesHome: Self.hidesHome(services.sidebarLayout.document),
                                                              newTabPages: Self.newTabPages(services.agentTabs, in: services.machines.local.store),
                                                              muted: services.notifications.preferences.mutedWorkspaces,
                                                              top: .make(services.sidebarLayout, machines: services.machines, room: state.profileID.rawValue),
                                                              tabTitle: Self.tabTitle(services),
                                                              groupConfig: services.settings?.snapshot.workspaceGroups ?? WorkspaceGroupConfig(),
                harnessIcons: { [weak services] in services?.harnessIconLookup ?? .none })
        show(sections, shownAt: shownAt, layout: SidebarRows.visibleLayout(services, window: state), launching: launching, failed: failed)
    }

    /// Shows `live` with loading sections filled from the seed, and the
    /// band's `layout` in the same turn, then saves it.
    private func show(_ live: [SidebarRowSection], shownAt: UInt64?, layout: SidebarLayoutDocument, launching: Bool, failed: Set<MachineID>,
                      creating: [PendingWorkspaceRows.Row] = []) {
        var sections = seed.connecting.holdingConnectingLabels(seed.merge(live, launching: launching, failed: failed))
        // After the merge, so a reconnecting machine's saved rows stand in first (cx-gaq9).
        if !model.groupsByComputer { sections = SSHConnectingRows.adding(services.machines, to: sections) }
        let hadDocDrag = model.docDrag != nil
        model.docDrag = SidebarDocWiring.docMachines(services.machines).drag() // the sidebar document's drag half, nil keeps the older resolver
        if let id = state?.id { model.docDrag?.listedElsewhere = WorkspaceLayoutRefs(machines: services.machines).listedElsewhere(window: id, registry: services.windows.registry) }
        model.docDrag?.room = state?.profileID.rawValue
        model.ungroupedFirst = model.docDrag == nil && !usesMixedOrder
        if model.layout != layout { model.layout = layout }
        // A pass that lists what the rows show already (a daemon reorder the personal or document order hides, a store
        // snapshot laid over again) sets no sections: no arrange and compare of every row in the main thread's frame.
        let elsewhere = model.docDrag.flatMap { drag in SidebarDocStore.current?.shown?.bandGroupsNotListedHere(drag: drag) }
        rows.show(sections, shownAt: shownAt, creating: (creating, NewWorkspacePlacements.home(services.machines)), unlessShown: hadDocDrag == (model.docDrag != nil),
                  elsewhere: elsewhere, showAppStore: services.settings?.snapshot.previewFeatures == true)
        selectionHold.flush()
        organizationQueue.drain(loaded: usesPersonalOrganization, local: services.machines.local, run: handle, refuse: refuseOrganization)
        groupFlow.openPendingEditor()
        if seed.isReadyForReveal(sections, launching: launching) { markReadyForReveal() }
        recordSnapshot()
    }

    private func showProfiles(_ profiles: [SidebarProfile], active: SidebarProfileKey?, launching: Bool) {
        if launching, profiles.isEmpty, let seededProfiles {
            if model.profiles != seededProfiles.profiles { model.profiles = seededProfiles.profiles }
            if model.activeProfileID != seededProfiles.active { model.activeProfileID = seededProfiles.active }
            return
        }
        seededProfiles = nil
        if model.profiles != profiles { model.profiles = profiles }
        if model.activeProfileID != active { model.activeProfileID = active }
        // `show` records the snapshot right after, with the new space's rows.
    }

    func recordSnapshot() {
        guard let state else { return }
        snapshotRecorder.record(model, window: state.id, services: services)
    }

    private func markReadyForReveal() {
        guard !isReadyForReveal else { return }
        isReadyForReveal = true
        DebugTimings.markLaunch("sidebar_rows_shown")
        services.launchReveal.markReady(.sidebar)
    }

    /// The window's live sidebar, whether the app is still launching (its
    /// saved rows stand in until then), and the Cloud machines whose first
    /// connection gave up (their launch placeholders end). Rows from the
    /// daemon's launch snapshot are `.stale` until the live tree replaces them.
    static func liveSections(_ machines: MachineRegistry, registry: WindowRegistryStore,
                             window: WindowState, creations: CloudCreations? = nil, hidesHome: Bool = true,
                             newTabPages: Set<String> = [], muted: Set<String> = [],
                             top: SidebarTopProjection = .legacy, pageFace: @escaping PageFace = { _, _, _ in nil },
                             tabTitle: TabTitle? = nil, rows: SidebarMapping.RowSource? = nil,
                             groupConfig: WorkspaceGroupConfig = WorkspaceGroupConfig(),
                             workspaceFilter: @escaping (WorkspaceModel) -> Bool = {
                                 AgentLaneStore.shared.keepsWorkspace($0, turns: AgentTurnStateStore.shared)
                             }, harnessIcons: @escaping () -> HarnessIconLookup = { .none }) -> ([SidebarRowSection], Bool, Set<MachineID>) {
        var sections = Self.sections(machines, members: registry.members(of: window.id), profile: window.profileID, hidesHome: hidesHome,
                                     selection: window.selection, newTabPages: newTabPages, muted: muted, top: top, pageFace: pageFace,
                                     tabTitle: tabTitle, rows: rows, workspaceFilter: workspaceFilter, harnessIcons: harnessIcons)
        // cmux.json `workspaceGroups.byCwd`: a configured group's color and icon.
        sections = WorkspaceGroupConfigLook(config: groupConfig, machines: machines).applying(to: sections)
        if let creations { sections = CloudCreationRows.adding(creations.shown(in: window.id), to: sections) }
        if machines.local.store.isProvisional { sections = SidebarRowSection.stale(sections) }
        // Debug Settings: sample rows to compare the row badges and the row names.
        sections += SidebarRowSection.debugPreviews()
        let failed = Set(machines.cloud.filter { $0.daemon.startup.isUnavailable }.map { MachineID($0.daemon.machineID) })
        return (sections, isLaunching(machines.local, registry: registry), failed)
    }

    /// Until the saved windows are restored from the live tree, unless the
    /// local daemon is unavailable (the connecting view says why).
    static func isLaunching(_ local: DaemonService, registry: WindowRegistryStore) -> Bool {
        registry.isLaunching && !local.startup.isUnavailable
    }

    /// This window's sidebar: every machine section, listing only the
    /// workspaces the window owns (`WindowRegistry`) in the profile it shows
    /// (`WindowProfiles`).
    /// `selection` is the window's tab selection: each row's type glyph shows its selected tab.
    /// `newTabPages` are the New Tab page tabs (`AgentTabs.pageTabs`); `muted` rows draw the muted mark.
    static func sections(_ machines: MachineRegistry, members: [String],
                         profile: ProfileID, hidesHome: Bool = true, selection: @autoclosure @escaping () -> TabSelectionMemory = .init(),
                         newTabPages: Set<String> = [], muted: Set<String> = [], top: SidebarTopProjection = .legacy,
                         pageFace: @escaping PageFace = { _, _, _ in nil }, tabTitle: TabTitle? = nil, rows: SidebarMapping.RowSource? = nil,
                         workspaceFilter: @escaping (WorkspaceModel) -> Bool = {
                             AgentLaneStore.shared.keepsWorkspace($0, turns: AgentTurnStateStore.shared)
                         }, harnessIcons: @escaping () -> HarnessIconLookup = { .none }) -> [SidebarRowSection] {
        let visible = WindowProfiles.visible(members, profile: profile, machines: machines)
        let filtered = SidebarRowSection.filter(sections(machines, profile: profile, hidesHome: hidesHome, selection: selection(), newTabPages: newTabPages,
                                                         muted: muted, pageFace: pageFace, tabTitle: tabTitle, rows: rows,
                                                         workspaceFilter: workspaceFilter, harnessIcons: harnessIcons),
                                                members: Set(ClosingWorkspaces.shared.survivors(visible)))
        return top.apply(to: filtered, machines: machines)
    }

    /// Whether the workspace list leaves the home workspace out: only while
    /// a Home item shows it, so it is never unreachable from the sidebar.
    /// The page face of a browser workspace's front tab, given the work tab it
    /// yields its name to (`AppServices.sidebarPageFace`).
    typealias PageFace = (WorkspaceModel, TabModel, TabModel?) -> SidebarMapping.PageFace?
    /// A tab's name in the sidebar (a row's title, its hover card), as its strip names it.
    typealias TabTitle = (TabModel) -> String

    /// The tabs that show the New Tab page, named "New Tab" and badged as a page.
    static func newTabPages(_ tabs: AgentTabStore, in store: DaemonStore?) -> Set<String> {
        RestoredNewTabPages.ids(in: store, tabs: tabs)
    }

    /// The strip's title rule (`TabTitleResolver`) for the sidebar's tab names.
    static func tabTitle(_ services: AppServices) -> TabTitle {
        let titles = TabTitleResolver(services: services)
        return { titles.title($0) }
    }

    static func hidesHome(_ layout: SidebarLayoutDocument) -> Bool {
        layout.firstItem(with: SidebarLayoutDocument.homeRef) != nil
    }

    /// One section per machine: the local daemon, then each Cloud machine
    /// (empty while it connects), with the workspaces and groups of
    /// `profile` (all of them on a machine without that profile).
    /// `selection` is read by each row's mapping (lazily), so a tab switch re-maps rows, not the sidebar.
    static func sections(_ machines: MachineRegistry, profile: ProfileID, hidesHome: Bool = true,
                         selection: @autoclosure @escaping () -> TabSelectionMemory = .init(), newTabPages: Set<String> = [], muted: Set<String> = [],
                         pageFace: @escaping PageFace = { _, _, _ in nil }, tabTitle: TabTitle? = nil, rows: SidebarMapping.RowSource? = nil,
                         workspaceFilter: @escaping (WorkspaceModel) -> Bool = {
                             AgentLaneStore.shared.keepsWorkspace($0, turns: AgentTurnStateStore.shared)
                         }, harnessIcons: @escaping () -> HarnessIconLookup = { .none }) -> [SidebarRowSection] {
        let showsUnread = DesignSettings.shared.attention.showsOnSidebar
        let selectedTab = { (pane: PaneModel) in selection().selection(in: pane.id) }
        let groupIcon = IconAssetImages.shared.sidebarIcon(owner: machines.local)
        var sections = SidebarMapping.shared.sections(PersonalSidebar.sections(of: machines.local, room: profile, machines: machines),
                                               machine: machine(for: machines.local, name: Strings.localMachine, kind: .local),
                                               hidesHomeWorkspace: hidesHome, showsUnread: showsUnread, muted: muted, selectedTab: selectedTab,
                                               newTabPages: newTabPages, newTabTitle: Strings.untitledBrowser, pageFace: pageFace,
                                               tabTitle: tabTitle, notificationText: machines.local.store.notificationText(for:),
                                               iconAsset: groupIcon, rowSource: rows, workspaceFilter: workspaceFilter,
                                               harnessIcons: harnessIcons)
        for session in machines.cloud {
            let header = CloudCreationRows.machine(session, compatibility: machines.compatibility(of: session.daemon), limits: machines.cloudLimits,
                                                   updates: machines.updates)
            sections += SidebarMapping.shared.sections(PersonalSidebar.sections(of: session.daemon, room: profile, machines: machines),
                                                machine: header, showsUnread: showsUnread, muted: muted, selectedTab: selectedTab,
                                                newTabPages: newTabPages, newTabTitle: Strings.untitledBrowser, pageFace: pageFace,
                                                tabTitle: tabTitle, notificationText: session.daemon.store.notificationText(for:),
                                                iconAsset: IconAssetImages.shared.sidebarIcon(owner: session.daemon), groupIconAsset: groupIcon,
                                                rowSource: rows, workspaceFilter: workspaceFilter)
        }
        for session in machines.ssh {
            sections += SidebarMapping.shared.sections(PersonalSidebar.sections(of: session.daemon, room: profile, machines: machines),
                                                machine: sshMachine(session, machines: machines), muted: muted, selectedTab: selectedTab,
                                                newTabPages: newTabPages, newTabTitle: Strings.untitledBrowser, pageFace: pageFace,
                                                tabTitle: tabTitle, notificationText: session.daemon.store.notificationText(for:),
                                                iconAsset: IconAssetImages.shared.sidebarIcon(owner: session.daemon), groupIconAsset: groupIcon,
                                                rowSource: rows, workspaceFilter: workspaceFilter)
        }
        for session in machines.servers {
            sections += SidebarMapping.shared.sections(PersonalSidebar.sections(of: session.daemon, room: profile, machines: machines),
                                                machine: session.sidebarMachine(machines: machines), selectedTab: selectedTab, pageFace: pageFace,
                                                tabTitle: tabTitle, notificationText: session.daemon.store.notificationText(for:),
                                                iconAsset: IconAssetImages.shared.sidebarIcon(owner: session.daemon), groupIconAsset: groupIcon,
                                                rowSource: rows, workspaceFilter: workspaceFilter)
        }
        return machines.withMachineIcons(sections)
    }

    static func machine(for daemon: DaemonService, name: String, kind: SidebarMachine.Kind, live: Bool = true,
                        compatibility: DaemonCompatibility? = nil) -> SidebarMachine {
        var status: SidebarMachine.Status = switch daemon.store.connectionState {
        case .connected: .connected
        case .connecting, .disconnected: live ? .connecting : .offline
        case .failed: live ? .connecting : .offline
        }
        // A remote machine keeps its own cmux-tui build: say when it is too
        // old instead of showing it as connecting (or silently limited).
        let compat = kind == .local ? nil : (compatibility ?? daemon.compatibility)
        if let compat, live {
            switch compat.level {
            case .incompatible where daemon.startup.isUnavailable: status = .updateRequired
            case .limited where status == .connected: status = .updateAvailable
            default: break
            }
        }
        let detail = (status == .updateRequired || status == .updateAvailable) ? compat.map(CloudStrings.compatibility) : nil
        return SidebarMachine(id: MachineID(daemon.machineID), name: name, kind: kind, status: status, detail: detail)
    }

    func contextMenu(for target: SidebarContextTarget) -> NSMenu? {
        switch target {
        // A pinned workspace's tile has its row's menu: name, colors, Unpin (a tile's
        // generic item menu had no colors, 2026-10-21), then the tile's Show/Hide Label.
        case .layoutItem(let id):
            if let workspace = pinnedWorkspaceID(ofItem: id),
               let ref = (model.layout.item(id) ?? model.listedItem(id))?.ref,
               let (_, owner) = WorkspaceLayoutRefs(machines: services.machines).workspace(for: ref) {
                SidebarContextMenus.menu(for: .workspaces([workspace]), model: model, services: services, scope: container.themeScope.fullStrength,
                                         trailing: tileRows(id), workspaceMachineID: owner.machineID)
            } else {
                layoutItemMenu(id)?.themeRows(in: container.themeScope.fullStrength)
            }
        case .layoutSection(let id): layoutSectionMenu(id)?.themeRows(in: container.themeScope.fullStrength)
        default: SidebarContextMenus.menu(for: target, model: model, services: services, scope: container.themeScope.fullStrength)
        }
    }

    // MARK: Persistence mirror

    /// Applies saved state without animating.
    func restore(width: Double?, hidden: Bool) {
        container.restore(width: width.map { CGFloat($0) }, presentation: hidden ? .hidden : .shown)
    }
}

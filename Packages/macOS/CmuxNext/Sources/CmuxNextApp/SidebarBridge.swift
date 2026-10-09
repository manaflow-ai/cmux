import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
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
    private var observation: Task<Void, Never>?
    private var selectionObservation: Task<Void, Never>?
    private var widthObservation: Task<Void, Never>?
    /// Item presentation for sidebar sections (SidebarBridge+Sections).
    var sectionsObservation: Task<Void, Never>?
    /// The optional Chats section (`sidebar.showChats`, SIDEBAR-NO-RECENTS).
    let chatsMount = SidebarChatsMount()
    var cardsObservation: Task<Void, Never>?
    /// True once the sidebar shows real content: saved rows, the first
    /// live rows, or a settled empty or unavailable state, which marks the
    /// sidebar region ready for `LaunchReveal`.
    private(set) var isReadyForReveal = false
    /// The window's saved rows, shown until live data replaces them.
    private var seed = SidebarSeed()
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
    /// The item the last Cmd-Ctrl-[ / ] reached and the workspace shown then (R119).

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
        container.sidebarView.resourceSource = services.resources
        container.sidebarView.hoverCards = services.hoverCards
        container.sidebarView.appSections = chatsMount.makeSections(services: services)
        // Return or Escape in the inline rename field gives the keyboard
        // back to the focused content (plans/cmux-next/focus.md R8).
        container.sidebarView.onRenameEnded = { [weak state] byKeyboard in
            guard byKeyboard, let focus = state?.focus else { return }
            focus.send(.focusTarget(.content, source: .keyboard))
        }
        seedFromSnapshot(state)
        // Clear until real content (released by `markReadyForReveal`, or by
        // the reveal deadline); a no-op once the sidebar region is ready.
        services.launchReveal.hold(container, until: .sidebar)
        observe()
        observeSections()
        observeCards()
    }

    func teardown() {
        observation?.cancel()
        selectionObservation?.cancel()
        widthObservation?.cancel()
        sectionsObservation?.cancel()
        cardsObservation?.cancel()
    }

    private func observe() {
        let machines = services.machines
        let registry = services.windows.registry
        let layout = services.sidebarLayout
        let pageTabs = services.agentTabs.pageTabs
        let notifications = services.notifications
        guard let windowState = state else { return }
        observation = Task { [weak self] in
            // `state.id` is read inside: the launch window adopts a saved id.
            // The layout too: removing the Home item lists the home workspace.
            // And the New Tab pages (a chat lists as a chat) and the muted set.
            // The spaces and the current space come from the same observation
            // as the rows (cx-5k3r): a space switch reaches the sidebar as one
            // change (new space and its rows together), so the sidebar runs
            // one slide, not a slide of the old rows and then a row reload.
            for await (sections, launching, failed, profiles, active) in Observations({
                let (sections, launching, failed) = Self.liveSections(
                    machines, registry: registry, window: windowState, hidesHome: Self.hidesHome(layout.document),
                    newTabPages: pageTabs.ids, muted: notifications.preferences.mutedWorkspaces,
                    top: .make(layout, machines: machines, room: windowState.profileID.rawValue))
                return (sections, launching, failed, Self.profiles(machines.local.store), SidebarProfileKey(windowState.profileID.rawValue))
            }) {
                guard let self else { return }
                self.showProfiles(profiles, active: active, launching: launching)
                self.show(sections, launching: launching, failed: failed)
            }
        }
        // R99: the rows of another space, for the page beside the current one during a swipe.
        model.spaceSections = { [weak windowState, spaceCache] key in
            guard let windowState else { return [] }
            return spaceCache.sections(for: key) {
                Self.sections(machines, members: registry.members(of: windowState.id), profile: ProfileID(rawValue: key.rawValue),
                              hidesHome: Self.hidesHome(layout.document), selection: windowState.selection,
                              newTabPages: pageTabs.ids, muted: notifications.preferences.mutedWorkspaces,
                              top: SidebarTopProjection.make(layout, machines: machines, room: key.rawValue))
            }
        }
        let state = windowState
        let model = model
        widthObservation = Task { [weak self] in
            for await (width, presentation) in Observations({ (model.width, model.presentation) }) {
                guard let self else { return }
                state.sidebarWidth = Double(width)
                state.sidebarHidden = presentation == .hidden
                self.services.windows.recordSaver.stateDidChange(state)
            }
        }
        selectionObservation = Task { [weak self] in
            // One selection: the shown page's top item, else the shown workspace.
            for await selected in Observations({ SidebarNavigation.selectedItem(page: state.page, workspace: state.workspaceID,
                                                                                layout: layout.document, room: state.profileID.rawValue,
                                                                                refs: WorkspaceLayoutRefs(machines: machines)) }) {
                guard let self else { return }
                if self.model.selectedItem != selected {
                    self.model.selectedItem = selected
                    self.model.selection = self.model.activeWorkspaceID.map { [$0] } ?? []
                }
            }
        }
    }

    // MARK: Snapshot-first launch

    /// Draws the window's saved sidebar (`SidebarSnapshotStore`) before the
    /// window is presented, so its first frame has rows: its own saved
    /// rows, or for the window a launch opens before it knows the saved
    /// window ids, the most recently used window's. Loading sections with
    /// nothing saved show placeholder rows.
    private func seedFromSnapshot(_ state: WindowState) {
        let windows = services.windows!
        let isLaunchWindow = windows.controllers.isEmpty && windows.registry.isLaunching
        let saved = services.sidebarSnapshots.launchDocument.snapshot(for: state.id, fallback: isLaunchWindow)
        seed = SidebarSeed(sections: saved?.sidebarSections ?? [])
        // Collapsed sections: this window's view state, saved only in its sidebar snapshot.
        model.collapsedSections = Set((saved?.sidebarSections ?? []).filter(\.isCollapsed).map(\.id))
        if let saved, !saved.profiles.isEmpty {
            seededProfiles = (saved.sidebarProfiles, saved.sidebarActiveProfileID)
            model.profiles = saved.sidebarProfiles
            model.activeProfileID = saved.sidebarActiveProfileID
        }
        let (sections, launching, failed) = Self.liveSections(services.machines, registry: windows.registry, window: state,
                                                              hidesHome: Self.hidesHome(services.sidebarLayout.document),
                                                              newTabPages: services.agentTabs.pageTabs.ids,
                                                              muted: services.notifications.preferences.mutedWorkspaces,
                                                              top: .make(services.sidebarLayout, machines: services.machines, room: state.profileID.rawValue))
        show(sections, launching: launching, failed: failed)
    }

    /// Shows `live` with loading sections filled from the seed, then saves it.
    private func show(_ live: [SidebarRowSection], launching: Bool, failed: Set<MachineID>) {
        let sections = seed.merge(live, launching: launching, failed: failed)
        model.ungroupedFirst = !usesMixedOrder
        model.setSections(sections)
        organizationQueue.drain(loaded: usesPersonalOrganization, local: services.machines.local, run: handle, refuse: refuseOrganization)
        openPendingGroupEditor()
        if !launching || sections.contains(where: { $0.workspaces.contains { $0.rowState != .placeholder } }) { markReadyForReveal() }
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
                             window: WindowState, hidesHome: Bool = true,
                             newTabPages: Set<String> = [], muted: Set<String> = [],
                             top: SidebarTopProjection = .legacy) -> ([SidebarRowSection], Bool, Set<MachineID>) {
        var sections = Self.sections(machines, members: registry.members(of: window.id), profile: window.profileID, hidesHome: hidesHome,
                                     selection: window.selection, newTabPages: newTabPages, muted: muted, top: top)
        if machines.local.store.isProvisional { sections = SidebarSeed.stale(sections) }
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
                         profile: ProfileID, hidesHome: Bool = true, selection: TabSelectionMemory = .init(),
                         newTabPages: Set<String> = [], muted: Set<String> = [], top: SidebarTopProjection = .legacy) -> [SidebarRowSection] {
        let visible = WindowProfiles.visible(members, profile: profile, machines: machines)
        let filtered = SidebarMembership.filter(sections(machines, profile: profile, hidesHome: hidesHome, selection: selection,
                                                         newTabPages: newTabPages, muted: muted), members: Set(visible))
        return top.apply(to: filtered, machines: machines)
    }

    /// Whether the workspace list leaves the home workspace out: only while
    /// a Home item shows it, so it is never unreachable from the sidebar.
    static func hidesHome(_ layout: SidebarLayoutDocument) -> Bool {
        layout.firstItem(with: SidebarLayoutDocument.homeRef) != nil
    }

    /// The profile bar of the local daemon's profiles (empty when it has
    /// none; the bar hides below two).
    static func profiles(_ store: DaemonStore) -> [SidebarProfile] {
        store.profiles.sorted { $0.index < $1.index }.map { profile in
            SidebarProfile(id: SidebarProfileKey(profile.id.rawValue), name: profile.name,
                           color: profile.color.flatMap(GroupColor.init(rawValue:)), icon: profile.icon)
        }
    }

    /// One section per machine: the local daemon, then each Cloud machine
    /// (empty while it connects), with the workspaces and groups of
    /// `profile` (all of them on a machine without that profile).
    static func sections(_ machines: MachineRegistry, profile: ProfileID, hidesHome: Bool = true,
                         selection: TabSelectionMemory = .init(), newTabPages: Set<String> = [], muted: Set<String> = []) -> [SidebarRowSection] {
        let showsUnread = DesignSettings.shared.attention.showsOnSidebar
        let selectedTab = { (pane: PaneModel) in selection.selection(in: pane.id) }
        var sections = SidebarMapping.shared.sections(PersonalSidebar.sections(of: machines.local, room: profile, machines: machines),
                                               machine: machine(for: machines.local, name: Strings.localMachine, kind: .local),
                                               hidesHomeWorkspace: hidesHome, showsUnread: showsUnread, muted: muted, selectedTab: selectedTab,
                                               newTabPages: newTabPages, newTabTitle: Strings.untitledBrowser)
        for session in machines.cloud {
            let header = machine(for: session.daemon, name: session.machine.title, kind: .cloud, live: session.machine.status.isLive,
                                 compatibility: machines.compatibility(of: session.daemon))
            sections += SidebarMapping.shared.sections(PersonalSidebar.sections(of: session.daemon, room: profile, machines: machines),
                                                machine: header, showsUnread: showsUnread, muted: muted, selectedTab: selectedTab,
                                                newTabPages: newTabPages, newTabTitle: Strings.untitledBrowser)
        }
        for session in machines.ssh {
            sections += SidebarMapping.shared.sections(PersonalSidebar.sections(of: session.daemon, room: profile, machines: machines),
                                                machine: sshMachine(session, machines: machines), muted: muted, selectedTab: selectedTab,
                                                newTabPages: newTabPages, newTabTitle: Strings.untitledBrowser)
        }
        for session in machines.servers {
            sections += SidebarMapping.shared.sections(PersonalSidebar.sections(of: session.daemon, room: profile, machines: machines),
                                                machine: session.sidebarMachine(machines: machines), selectedTab: selectedTab)
        }
        return sections
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
        let registry = services.registry
        switch target {
        case .workspaces(let ids):
            // A placeholder row is no workspace yet: no menu, not one that does nothing.
            guard let first = ids.first, !ids.contains(where: { model.workspace($0)?.rowState == .placeholder }) else { return nil }
            return registry.makeContextMenu(for: .workspaceRow, target: ActionTargetRef(kind: .workspace, id: first.rawValue))
        case .group(let id):
            return registry.makeContextMenu(for: .workspaceGroup, target: ActionTargetRef(kind: .workspaceGroup, id: id.rawValue))
        case .section(.machine(let machine)) where services.machines.sshSession(machine.rawValue) != nil:
            return registry.makeContextMenu(for: .sshMachine, target: ActionTargetRef(kind: .machine, id: machine.rawValue))
        case .section(.machine(let machine)) where services.machines.server(machine.rawValue) != nil:
            return registry.makeContextMenu(for: .sidebarBackground)
        case .section(.machine(let machine)) where machine.rawValue != MachineRegistry.localID:
            return registry.makeContextMenu(for: .cloudMachine, target: ActionTargetRef(kind: .machine, id: machine.rawValue))
        case .section, .background:
            return registry.makeContextMenu(for: .sidebarBackground)
        case .profile(let id):
            return registry.makeContextMenu(for: .profile, target: ActionTargetRef(kind: .profile, id: id.rawValue))
        case .layoutItem(let id):
            return layoutItemMenu(id)
        case .layoutSection(let id):
            return layoutSectionMenu(id)
        }
    }

    // MARK: Persistence mirror

    /// Applies saved state without animating.
    func restore(width: Double?, hidden: Bool) {
        container.restore(width: width.map { CGFloat($0) }, presentation: hidden ? .hidden : .shown)
    }
}

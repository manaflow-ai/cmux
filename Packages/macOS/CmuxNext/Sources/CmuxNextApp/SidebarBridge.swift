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
    let model = SidebarModel()
    let container: SidebarContainerView
    unowned let services: AppServices
    /// Weak: a daemon command's `Task` can outlive the window.
    weak var state: WindowState?
    private var observation: Task<Void, Never>?
    private var selectionObservation: Task<Void, Never>?
    private var widthObservation: Task<Void, Never>?
    private var profileObservation: Task<Void, Never>?
    /// Item presentation for sidebar sections (SidebarBridge+Sections).
    var sectionsObservation: Task<Void, Never>?
    /// True once the sidebar shows real content: saved rows, the first
    /// live rows, or a settled empty or unavailable state, which marks the
    /// sidebar region ready for `LaunchReveal`.
    private(set) var isReadyForReveal = false
    /// The window's saved rows, shown until live data replaces them.
    private var seed = SidebarSeed()
    /// The saved space bar, shown until the local daemon reports its spaces.
    private var seededProfiles: (profiles: [SidebarProfile], active: SidebarProfileKey?)?
    /// What was last saved for this window, and the order of saves.
    private var lastRecorded: SidebarSnapshot?
    private var recordSequence: UInt64 = 0
    /// Once incognito, never saved, even after the window leaves the
    /// incognito set on its way out.
    private var everIncognito = false

    init(services: AppServices, state: WindowState) {
        self.services = services
        self.state = state
        container = SidebarContainerView(model: model)
        model.onIntent = { [weak self] intent in self?.handle(intent) }
        model.ungroupedFirst = true
        // Synchronous, before the hide animation starts: focus leaves the
        // sidebar in the same turn (plans/cmux-next/focus.md).
        model.onPresentationChange = { [weak state] presentation in
            state?.focus.send(.sidebarVisibility(hidden: presentation == .hidden))
        }
        container.sidebarView.contextMenuProvider = { [weak self] target in self?.contextMenu(for: target) }
        container.sidebarView.resourceSource = services.resources
        container.sidebarView.hoverCards = services.hoverCards
        container.sidebarView.appSections = SidebarAppSections(registry: services.apps.registry, host: services.apps.host)
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
    }

    func teardown() {
        observation?.cancel()
        selectionObservation?.cancel()
        widthObservation?.cancel()
        profileObservation?.cancel()
        sectionsObservation?.cancel()
    }

    private func observe() {
        let machines = services.machines
        let registry = services.windows.registry
        let layout = services.sidebarLayout
        guard let windowState = state else { return }
        observation = Task { [weak self] in
            // `state.id` is read inside: the launch window adopts a saved id.
            // The layout too: removing the Home item lists the home workspace.
            for await (sections, launching, failed) in Observations({
                Self.liveSections(machines, registry: registry, window: windowState, hidesHome: Self.hidesHome(layout.document))
            }) {
                self?.show(sections, launching: launching, failed: failed)
            }
        }
        profileObservation = Task { [weak self] in
            for await (profiles, active, launching) in Observations({
                (Self.profiles(machines.local.store), SidebarProfileKey(windowState.profileID.rawValue),
                 Self.isLaunching(machines.local, registry: registry))
            }) {
                self?.showProfiles(profiles, active: active, launching: launching)
            }
        }
        // R99: the rows of another space, for the page beside the current one during a swipe.
        model.spaceSections = { [weak windowState] key in
            guard let windowState else { return [] }
            return Self.sections(machines, members: registry.members(of: windowState.id), profile: ProfileID(rawValue: key.rawValue),
                                 hidesHome: Self.hidesHome(layout.document))
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
            for await id in Observations({ state.workspaceID }) {
                guard let self else { return }
                let selected = id.map { SidebarWorkspaceID($0) }
                if self.model.activeWorkspaceID != selected {
                    self.model.activeWorkspaceID = selected
                    self.model.selection = selected.map { [$0] } ?? []
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
        if let saved, !saved.profiles.isEmpty {
            seededProfiles = (saved.sidebarProfiles, saved.sidebarActiveProfileID)
            model.profiles = saved.sidebarProfiles
            model.activeProfileID = saved.sidebarActiveProfileID
        }
        let (sections, launching, failed) = Self.liveSections(services.machines, registry: windows.registry, window: state,
                                                              hidesHome: Self.hidesHome(services.sidebarLayout.document))
        show(sections, launching: launching, failed: failed)
    }

    /// Shows `live` with loading sections filled from the seed, then saves it.
    private func show(_ live: [SidebarRowSection], launching: Bool, failed: Set<MachineID>) {
        let sections = seed.merge(live, launching: launching, failed: failed)
        if model.sections != sections { model.sections = sections }
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
        recordSnapshot()
    }

    /// Saves what the sidebar shows (placeholders and live-only detail
    /// left out) once the launch is over, only for an open registered
    /// window and never an incognito one (a closing incognito window leaves
    /// the incognito set before its sidebar goes away).
    private func recordSnapshot() {
        let registry = services.windows.registry
        guard let state else { return }
        if registry.value.isIncognito(state.id) { everIncognito = true }
        guard !everIncognito, !registry.isLaunching, registry.value.window(state.id)?.isOpen == true else { return }
        let snapshot = SidebarSnapshot(sections: model.sections, profiles: model.profiles, activeProfileID: model.activeProfileID)
        guard snapshot != lastRecorded else { return }
        lastRecorded = snapshot
        recordSequence += 1
        let store = services.sidebarSnapshots, window = state.id, sequence = recordSequence
        Task { await store.record(snapshot, window: window, sequence: sequence) }
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
                             window: WindowState, hidesHome: Bool = true) -> ([SidebarRowSection], Bool, Set<MachineID>) {
        var sections = Self.sections(machines, members: registry.members(of: window.id), profile: window.profileID, hidesHome: hidesHome)
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
    static func sections(_ machines: MachineRegistry, members: [String],
                         profile: ProfileID, hidesHome: Bool = true) -> [SidebarRowSection] {
        let visible = WindowProfiles.visible(members, profile: profile, machines: machines)
        let pinned = Set(machines.daemons.flatMap { $0.store.workspaces.filter(\.pinned).map(\.id) })
        let filtered = SidebarMembership.filter(sections(machines, profile: profile, hidesHome: hidesHome), members: Set(visible))
        return SidebarMembership.pinnedFirst(filtered, pinned: pinned)
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
    static func sections(_ machines: MachineRegistry, profile: ProfileID, hidesHome: Bool = true) -> [SidebarRowSection] {
        let showsUnread = DesignSettings.shared.attention.showsOnSidebar
        var sections = SidebarMapping.shared.sections(PersonalSidebar.sections(of: machines.local, room: profile, machines: machines),
                                               machine: machine(for: machines.local, name: Strings.localMachine, kind: .local),
                                               hidesHomeWorkspace: hidesHome, showsUnread: showsUnread)
        for session in machines.cloud {
            let header = machine(for: session.daemon, name: session.machine.title, kind: .cloud, live: session.machine.status.isLive,
                                 compatibility: machines.compatibility(of: session.daemon))
            sections += SidebarMapping.shared.sections(PersonalSidebar.sections(of: session.daemon, room: profile, machines: machines),
                                                machine: header, showsUnread: showsUnread)
        }
        for session in machines.ssh {
            sections += SidebarMapping.shared.sections(PersonalSidebar.sections(of: session.daemon, room: profile, machines: machines),
                                                machine: sshMachine(session, machines: machines))
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

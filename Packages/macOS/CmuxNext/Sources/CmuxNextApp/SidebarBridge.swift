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
    /// live rows, or a settled empty or unavailable state (LaunchReveal).
    private(set) var isReadyForReveal = false
    /// The window's saved rows, shown until live data replaces them.
    private var seed = SidebarSeed()
    /// The saved space bar, shown until the local daemon reports its spaces.
    private var seededProfiles: (profiles: [SidebarProfile], active: SidebarProfileKey?)?
    /// What was last saved for this window, and the order of saves.
    private var lastRecorded: SidebarSnapshot?
    private var recordSequence: UInt64 = 0

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
        // Return or Escape in the inline rename field gives the keyboard
        // back to the focused content (plans/cmux-next/focus.md R8).
        container.sidebarView.onRenameEnded = { [weak state] byKeyboard in
            guard byKeyboard, let focus = state?.focus else { return }
            focus.send(.focusTarget(.content, source: .keyboard))
        }
        seedFromSnapshot(state)
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
        let board = services.statusBoard
        let registry = services.windows.registry
        guard let windowState = state else { return }
        observation = Task { [weak self] in
            // `state.id` is read inside: the launch window adopts a saved id.
            for await (sections, launching) in Observations({
                Self.liveSections(machines, statuses: board, registry: registry, window: windowState)
            }) {
                self?.show(sections, launching: launching)
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
        let state = windowState
        let model = model
        widthObservation = Task { [weak self] in
            for await (width, presentation) in Observations({ (model.width, model.presentation) }) {
                guard let self else { return }
                state.sidebarWidth = Double(width)
                state.sidebarHidden = presentation == .hidden
                self.services.windows.stateDidChange(state)
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
        let (sections, launching) = Self.liveSections(services.machines, statuses: services.statusBoard, registry: windows.registry,
                                                      window: state)
        show(sections, launching: launching)
    }

    /// Shows `live` with loading sections filled from the seed, then saves it.
    private func show(_ live: [SidebarRowSection], launching: Bool) {
        let sections = seed.merge(live, launching: launching)
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
    /// left out) once the launch is over; never for an incognito window.
    private func recordSnapshot() {
        let registry = services.windows.registry
        guard let state, !registry.isLaunching, !registry.value.isIncognito(state.id) else { return }
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
        // LaunchReveal seam: call `markReady(.sidebar)` here once LaunchReveal lands on feat-cmux-next.
    }

    /// The window's live sidebar and whether the app is still launching
    /// (its saved rows stand in until then). Rows from the daemon's launch
    /// snapshot are `.stale` until the live tree replaces them.
    static func liveSections(_ machines: MachineRegistry, statuses: WorkspaceStatusBoard, registry: WindowRegistryStore,
                             window: WindowState) -> ([SidebarRowSection], Bool) {
        var sections = Self.sections(machines, statuses: statuses, members: registry.members(of: window.id), profile: window.profileID)
        if machines.local.store.isProvisional { sections = SidebarSeed.stale(sections) }
        return (sections, isLaunching(machines.local, registry: registry))
    }

    /// Until the saved windows are restored from the live tree, unless the
    /// local daemon is unavailable (the connecting view says why).
    static func isLaunching(_ local: DaemonService, registry: WindowRegistryStore) -> Bool {
        registry.isLaunching && !local.startup.isUnavailable
    }

    /// This window's sidebar: every machine section, listing only the
    /// workspaces the window owns (`WindowRegistry`) in the profile it shows
    /// (`WindowProfiles`).
    static func sections(_ machines: MachineRegistry, statuses: WorkspaceStatusBoard, members: [String],
                         profile: ProfileID) -> [SidebarRowSection] {
        let visible = WindowProfiles.visible(members, profile: profile, machines: machines)
        let pinned = Set(machines.daemons.flatMap { $0.store.workspaces.filter(\.pinned).map(\.id) })
        let filtered = SidebarMembership.filter(sections(machines, statuses: statuses, profile: profile), members: Set(visible))
        return SidebarMembership.pinnedFirst(filtered, pinned: pinned)
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
    static func sections(_ machines: MachineRegistry, statuses: WorkspaceStatusBoard, profile: ProfileID) -> [SidebarRowSection] {
        let status = { (id: String) in statuses.line(for: id) }
        let showsUnread = DesignSettings.shared.attention.showsOnSidebar
        var sections = SidebarMapping.shared.sections(PersonalSidebar.sections(of: machines.local, room: profile, machines: machines),
                                               machine: machine(for: machines.local, name: Strings.localMachine, kind: .local),
                                               showsUnread: showsUnread, statusLine: status)
        for session in machines.cloud {
            let header = machine(for: session.daemon, name: session.machine.title, kind: .cloud, live: session.machine.status.isLive,
                                 compatibility: machines.compatibility(of: session.daemon))
            sections += SidebarMapping.shared.sections(PersonalSidebar.sections(of: session.daemon, room: profile, machines: machines),
                                                machine: header, showsUnread: showsUnread, statusLine: status)
        }
        for session in machines.ssh {
            sections += SidebarMapping.shared.sections(PersonalSidebar.sections(of: session.daemon, room: profile, machines: machines),
                                                machine: sshMachine(session, machines: machines), statusLine: status)
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
            return registry.makeContextMenu(for: .sidebarSection, target: ActionTargetRef(kind: .sidebarSection, id: id.rawValue))
        }
    }

    // MARK: Persistence mirror

    /// Applies saved state without animating.
    func restore(width: Double?, hidden: Bool) {
        container.restore(width: width.map { CGFloat($0) }, presentation: hidden ? .hidden : .shown)
    }
}

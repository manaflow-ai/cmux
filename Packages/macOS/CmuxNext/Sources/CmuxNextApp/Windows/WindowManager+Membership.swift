import AppKit
import CmuxNextDaemon
import Observation

// Window membership transitions. Every change goes through `transition`,
// which applies one `WindowRegistry` step and then `sync`s controllers and
// each window's selection to it. Window membership is frontend-local: no
// daemon command here (structural moves are sent by their callers).
extension WindowManager {
    // MARK: Transitions

    /// Applies one registry transition. `select` names, per window, the
    /// workspaces the user just moved in; the first becomes selected there.
    @discardableResult
    func transition(select preferred: [String: [String]] = [:],
                    _ body: (inout WindowRegistry) -> WindowRegistry.Changes) -> WindowRegistry.Changes {
        let before = registry.value
        let previous = Dictionary(before.windows.map { ($0.id, $0.workspaceIDs) }, uniquingKeysWith: { first, _ in first })
        let live = services.machines.daemons.flatMap { Self.orderedIDs(of: $0, machines: self.services.machines) }
        let changes = registry.apply { registry in
            let changes = body(&registry)
            registry.order(like: live)
            return changes
        }
        if registry.value != before || !preferred.isEmpty {
            // Focus follows the workspaces: the window that received them.
            let receivers = Array(preferred.keys) + changes.moved.keys.sorted()
            sync(previous: previous, preferred: preferred, receivers: receivers)
        }
        return changes
    }

    /// Makes controllers match the registry, all in this main-actor turn so
    /// no frame shows a window without its workspace: opens missing windows,
    /// repairs each window's selection, closes windows the registry removed
    /// or closed (at once), and when the key window closed, makes the window
    /// that received its workspaces key (else the next one in z-order).
    /// Windows whose membership did not change keep their state untouched.
    func sync(previous: [String: [String]], preferred: [String: [String]] = [:], receivers: [String] = []) {
        let value = registry.value
        for window in value.openWindows where controller(for: window.id) == nil {
            makeController(for: window)
        }
        repairSelections(previous: previous, preferred: preferred)
        let closing = controllers.filter { $0.state.id != launchWindowID && value.window($0.state.id)?.isOpen != true }
        let closedKey = closing.contains { $0.window?.isKeyWindow == true }
        for controller in closing { closeProgrammatically(controller) }
        for id in Array(states.keys) where value.window(id) == nil && id != launchWindowID { states[id] = nil }
        if closedKey { handOffKey(to: receivers) }
        checkInvariants()
        // The last incognito window left (closed, or its last workspace
        // closed): its browser data goes.
        endIncognitoSessionIfUnused()
        recordIncognitoWorkspaces()
        scheduleSave()
    }

    /// Makes each window's selection a workspace it lists in its current
    /// profile. When that profile has none left there (closed, moved to
    /// another profile or window), the window shows the most recent other
    /// profile it holds workspaces in.
    func repairSelections(previous: [String: [String]], preferred: [String: [String]] = [:]) {
        let machines = services.machines
        let home = machines.local.store
        for window in registry.value.windows {
            let state = state(for: window.id)
            let room = state.profileID
            // Its room was deleted (here or by another client).
            if home.personal.isLoaded, home.profile(state.profileID) == nil {
                state.enterProfile(WindowProfiles.fallback(for: state, members: window.workspaceIDs, machines: machines) ?? .defaultProfile)
            }
            var visible = WindowProfiles.visible(window.workspaceIDs, profile: state.profileID, machines: machines)
            // A window waiting for the workspace it just created in a new
            // or empty room keeps that room.
            let waiting = pendingClaims.values.contains(window.id)
            if visible.isEmpty, !waiting,
               let fallback = WindowProfiles.fallback(for: state, members: window.workspaceIDs, machines: machines) {
                state.enterProfile(fallback)
                visible = WindowProfiles.visible(window.workspaceIDs, profile: fallback, machines: machines)
            }
            // A room change shows the workspace last shown in that room.
            var wanted = preferred[window.id] ?? []
            if state.profileID != room, let remembered = state.profileWorkspaces[state.profileID] { wanted.append(remembered) }
            let prior = WindowProfiles.visible(previous[window.id] ?? window.workspaceIDs, profile: state.profileID, machines: machines)
            let pick = WindowRegistry.repairedSelection(current: state.workspaceID, previous: prior,
                                                        members: visible, preferred: wanted)
            if state.workspaceID != pick { select(pick, in: state) }
        }
    }

    /// Makes the first open receiver key, else our frontmost window.
    private func handOffKey(to receivers: [String]) {
        guard ordersWindowsIn, !services.environment.noActivate else { return }
        let next = receivers.lazy.compactMap { self.controller(for: $0) }.first
            ?? NSApp.orderedWindows.lazy.compactMap { window in self.controllers.first { $0.window === window } }.first
        if let next { bringToFront(next) }
    }

    /// Counts and logs any broken window invariant after a transition.
    private func checkInvariants() {
        let problems = WindowInvariants.problems(self)
        guard !problems.isEmpty else { return }
        noteInvariantViolations(problems)
    }

    /// Sets the window's shown workspace (its own state).
    func select(_ workspaceID: String?, in state: WindowState) {
        if let workspaceID { enterProfile(of: workspaceID, in: state) }
        if let workspaceID, let machine = services.machines.daemon(forWorkspace: workspaceID)?.machineID { state.machineID = machine }
        state.workspaceID = workspaceID
        stateDidChange(state)
    }

    // MARK: Entry points

    /// Shows `workspaceID`: in the window that lists it (brought forward),
    /// else in `state`'s window, which takes it.
    func show(workspaceID: String, in state: WindowState) {
        let value = registry.value
        if let owner = value.owner(of: workspaceID), owner != state.id, value.window(owner)?.isOpen == true,
           let target = controller(for: owner) {
            select(workspaceID, in: target.state)
            bringToFront(target)
            return
        }
        claim(workspaceID: workspaceID, in: state)
    }

    /// Shows `workspaceID` where it lives: its window when open, else the
    /// active window takes it, else a new window. Returns that window.
    @discardableResult
    func reveal(workspaceID: String) -> WindowController? {
        let value = registry.value
        if let owner = value.owner(of: workspaceID), value.window(owner)?.isOpen == true, let target = controller(for: owner) {
            select(workspaceID, in: target.state)
            return target
        }
        if let active {
            claim(workspaceID: workspaceID, in: active.state)
            return active
        }
        return openWindow(workspaces: [workspaceID])
    }

    /// Moves `workspaceID` into `state`'s window and selects it there. Use
    /// for workspaces a window just created (drag to the sidebar, New
    /// Workspace), even before the daemon reports them.
    /// A workspace of an incognito window never moves into a normal one,
    /// nor the reverse: refused with a message.
    func claim(workspaceID: String, in state: WindowState) {
        if registry.value.crossesIncognito([workspaceID], to: state.id) {
            services.registry.refuse(RefusalStrings.incognitoMismatch)
            return
        }
        protectIfUnknown([workspaceID], window: state.id)
        if registry.value.owner(of: workspaceID) == state.id {
            select(workspaceID, in: state)
            return
        }
        transition(select: [state.id: [workspaceID]]) { $0.move([workspaceID], to: state.id) }
    }

    /// Moves workspaces into an existing window and selects the first there;
    /// a window left without workspaces closes.
    /// Returns false when nothing moved (a move between an incognito
    /// window and a normal one is refused with a message).
    @discardableResult
    func moveWorkspaces(_ ids: [String], toWindow windowID: String, select: Bool = true) -> Bool {
        guard registry.value.window(windowID)?.isOpen == true, !ids.isEmpty else { return false }
        if registry.value.crossesIncognito(ids, to: windowID) {
            services.registry.refuse(RefusalStrings.incognitoMismatch)
            return false
        }
        transition(select: select ? [windowID: ids] : [:]) { $0.move(ids, to: windowID) }
        return true
    }

    /// Opens a new window listing `workspaces` (taken from their windows,
    /// which close when left empty) and showing the first. Returns its
    /// controller; nil when `workspaces` is empty (no window without one).
    /// A workspace the daemon has not reported yet keeps the window off
    /// screen until its content is installed (`contentDidAppear`).
    /// `incognito` marks the new window (a tear-off from an incognito
    /// window whose workspace the daemon has not reported yet); known
    /// workspaces of incognito windows make it incognito anyway, and a mix
    /// of both kinds opens nothing (refused with a message).
    @discardableResult
    func openWindow(id: String = UUID().uuidString.lowercased(), workspaces: [String], frame: CGRect? = nil,
                    incognito: Bool = false) -> WindowController? {
        let kinds = Set(workspaces.compactMap { registry.value.owner(of: $0) }.map(registry.value.isIncognito))
        if kinds.count > 1 || (incognito && kinds == [false]) {
            services.registry.refuse(RefusalStrings.incognitoMismatch)
            return nil
        }
        if incognito { registry.apply { $0.markIncognito(id); return WindowRegistry.Changes() } }
        protectIfUnknown(workspaces, window: id)
        transition(select: [id: workspaces]) { $0.openWindow(id: id, workspaceIDs: workspaces, frame: frame) }
        guard let controller = controller(for: id) else { return nil }
        if let frame { controller.window?.setFrame(frame, display: true) }
        return controller
    }

    /// The user closed window `id`: its workspaces move to the most recent
    /// other window of its kind; the last window stays registered, closed,
    /// with its workspaces (restorable by a Dock click).
    /// An incognito window closes for good: its workspaces close too.
    func userClosed(_ id: String) {
        let changes = transition { $0.close(id) }
        discard(changes.discarded)
    }

    /// Reopens the last window after the user closed it (Dock click, Show
    /// cmux). Returns false when no closed window is registered.
    @discardableResult
    func reopenClosedWindow() -> Bool {
        var reopened: String?
        transition { registry in
            reopened = registry.reopen()
            return WindowRegistry.Changes()
        }
        guard let reopened, let controller = controller(for: reopened) else { return false }
        bringToFront(controller)
        return true
    }

    /// Closes a window the registry removed, at once and in the same turn
    /// as the transition (like a standard window close). A fade would keep
    /// the window on screen after its workspace left: either empty or
    /// fighting the receiving window for the same terminal surfaces. Never
    /// runs the user-close transition.
    func closeProgrammatically(_ controller: WindowController) {
        let id = controller.state.id
        guard !programmaticCloses.contains(id), let window = controller.window else { return }
        programmaticCloses.insert(id)
        window.close()
    }

    // MARK: Reconcile with the daemons

    /// Re-runs `reconcileMembership` whenever any machine's workspace list,
    /// load state, or the Cloud machine list changes.
    func observeMembership() {
        let machines = services.machines
        let cloud = services.cloud!
        membershipObservation?.cancel()
        membershipObservation = Task { [weak self] in
            for await _ in Observations({ () -> [String] in
                [String(cloud.hasLoadedMachines), String(cloud.isSignedIn)]
                    + machines.daemons.map { "\($0.machineID):\($0.store.isLoaded):\(Self.order(of: $0, machines: machines))" }
                    + [Self.profileTags(of: machines.local)]
            }) {
                self?.reconcileMembership()
            }
        }
    }

    /// The one place daemon truth prunes and fills windows: dead
    /// workspaces leave their windows (a window left with none closes),
    /// new ones join their claimed window (opening it) or the most recent
    /// one. Runs synchronously from each store's `onWorkspaceListChanged`,
    /// so a window closes in the same turn as the delta that emptied it,
    /// before any observer or frame; the observation loop above covers
    /// machine list and Cloud load changes.
    func reconcileMembership() {
        var live: [String] = []
        for daemon in services.machines.daemons {
            installWorkspaceListHook(on: daemon)
            for id in Self.orderedIDs(of: daemon, machines: services.machines) {
                live.append(id)
                seenMachine[id] = daemon.machineID
            }
        }
        var placements = pendingClaims
        // A tab moved out of an incognito window into a new workspace (drag,
        // action, CLI) keeps its kind: that workspace goes back to the
        // incognito window it came from, never to a normal one.
        let registered = registry.value
        for id in live where registered.owner(of: id) == nil && placements[id] == nil {
            let tabs = services.workspace(id: id)?.screens.flatMap(\.panes).flatMap(\.tabs).map(\.id) ?? []
            if let home = tabs.lazy.compactMap({ self.incognitoTabHomes[$0] }).first(where: { registered.window($0)?.isOpen == true }) {
                placements[id] = home
            }
        }
        for id in live { pendingClaims[id] = nil }
        // A claimed workspace is selected in its window.
        let before = registry.value
        var preferred: [String: [String]] = [:]
        for id in live where before.owner(of: id) == nil {
            if let window = placements[id] { preferred[window, default: []].append(id) }
        }
        let members = before.windows.flatMap(\.workspaceIDs)
        let dead = Set(members.filter(isDead))
        let fallback = launchWindowID ?? UUID().uuidString.lowercased()
        transition(select: preferred) { registry in
            registry.reconcile(live: live, dead: dead, placements: placements, fallbackWindow: fallback)
        }
        // A workspace that changed profile leaves no trace in membership.
        if registry.value == before, preferred.isEmpty { repairSelections(previous: [:]) }
        if let launch = launchWindowID, restored, registry.value.window(launch) != nil { launchWindowID = nil }
        rememberIncognitoTabs()
        applyPendingPlacements(live: Set(live))
    }

    private func installWorkspaceListHook(on daemon: DaemonService) {
        guard daemon.store.onWorkspaceListChanged == nil else { return }
        daemon.store.onWorkspaceListChanged = { [weak self] in self?.reconcileMembership() }
    }

    /// True when `id` is known gone: its machine is loaded and lacks it, or
    /// it was never seen and every machine that could hold it has loaded.
    func isDead(_ id: String) -> Bool {
        if pendingClaims[id] != nil || services.machines.workspace(id: id) != nil { return false }
        if let machine = seenMachine[id] {
            guard let daemon = services.machines.daemon(machine: machine) else { return cloudSettled }
            return daemon.store.isLoaded
        }
        return services.machines.local.store.isLoaded && cloudSettled
    }

    /// Every Cloud machine that could still report workspaces has loaded.
    private var cloudSettled: Bool {
        guard let cloud = services.cloud, cloud.isSignedIn || cloud.auth.isRestoring else { return true }
        guard cloud.hasLoadedMachines else { return false }
        return services.machines.cloud.allSatisfy { !$0.machine.status.isLive || $0.daemon.store.isLoaded }
    }

    /// Workspaces the daemon has not reported yet stay alive (and land in
    /// `window` if reconcile sees them as orphans) until it does.
    private func protectIfUnknown(_ ids: [String], window: String) {
        for id in ids where services.machines.workspace(id: id) == nil { pendingClaims[id] = window }
    }

    /// The daemon's workspace ids in sidebar order, then any it lists
    /// outside the sidebar.
    static func orderedIDs(of daemon: DaemonService, machines: MachineRegistry) -> [String] {
        if let personal = PersonalSidebar.orderedIDs(of: daemon, machines: machines) { return personal }
        let sidebar = daemon.store.sidebarSections.flatMap(\.workspaces).map(\.id)
        let listed = Set(sidebar)
        return sidebar + daemon.store.workspaces.map(\.id).filter { !listed.contains($0) }
    }

    /// Each workspace's profile and the profile list, so a profile move or
    /// a new profile re-runs reconcile.
    private static func profileTags(of daemon: DaemonService) -> String {
        "\(daemon.store.personal.revision)|" + daemon.store.profileIDs.map(\.rawValue).joined(separator: ",")
    }

    private static func order(of daemon: DaemonService, machines: MachineRegistry) -> String {
        orderedIDs(of: daemon, machines: machines).joined(separator: ",")
    }
}

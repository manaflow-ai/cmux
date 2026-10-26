import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextLayout
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
        recordSaver.scheduleSave()
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
            // Its room was deleted (here or by another client); cached rooms can lag.
            if home.personal.isLoaded, !home.isProvisional, home.profile(state.profileID) == nil {
                state.enterProfile(WindowProfiles.fallback(for: state, members: window.workspaceIDs, machines: machines) ?? .defaultProfile)
            }
            var visible = WindowProfiles.shown(window.workspaceIDs, profile: state.profileID, machines: machines)
            // A window waiting for the workspace it just created in a new
            // or empty room keeps that room.
            let waiting = pendingClaims.values.contains(window.id)
            if visible.isEmpty, !waiting,
               let fallback = WindowProfiles.fallback(for: state, members: window.workspaceIDs, machines: machines) {
                state.enterProfile(fallback)
                visible = WindowProfiles.shown(window.workspaceIDs, profile: fallback, machines: machines)
            }
            // A room change shows the workspace last shown in that room.
            var wanted = preferred[window.id] ?? []
            if state.profileID != room, let remembered = state.profileWorkspaces[state.profileID] { wanted.append(remembered) }
            let prior = WindowProfiles.visible(previous[window.id] ?? window.workspaceIDs, profile: state.profileID, machines: machines)
            // "The next row" is the sidebar's next drawn row, not the next member to have joined.
            let pick = WindowRegistry.repairedSelection(current: state.workspaceID, previous: prior, members: visible, preferred: wanted, orders:
                (controller(for: window.id)?.sidebar.model).map { [$0.drawnWorkspaceOrder().map(\.rawValue), $0.allWorkspaces.map(\.id.rawValue)] } ?? [])
            if state.workspaceID != pick { select(pick, in: state, keepsCreation: true) }
        }
    }

    /// Makes the first open receiver key, else our frontmost window.
    private func handOffKey(to receivers: [String]) {
        guard ordersWindowsIn, !services.environment.noActivate else { return }
        let next = receivers.lazy.compactMap { self.controller(for: $0) }.first
            ?? registry.value.recency.lazy.compactMap { self.controller(for: $0) }.first { $0.window?.isVisible == true }
        if let next { bringToFront(next) }
    }

    /// Counts and logs any broken window invariant after a transition.
    private func checkInvariants() {
        let problems = WindowInvariants.problems(self)
        guard !problems.isEmpty else { return }
        noteInvariantViolations(problems)
    }

    /// Sets the window's shown workspace (its own state); see `WindowState.showWorkspace(_:keepsCreation:)`.
    func select(_ workspaceID: String?, in state: WindowState, keepsCreation: Bool = false) {
        if let workspaceID { enterProfile(of: workspaceID, in: state) }
        if let workspaceID, let machine = services.machines.daemon(forWorkspace: workspaceID)?.machineID { state.machineID = machine }
        state.showWorkspace(workspaceID, keepsCreation: keepsCreation || services.cloud.creations.opens(workspaceID, shownIn: state))
        recordSaver.stateDidChange(state)
    }

    // MARK: Entry points

    /// Shows `workspaceID`: in the window that lists it (brought forward),
    /// else in `state`'s window, which takes it. With `origin` `.thisWindow`
    /// (a person's pick in `state`'s own sidebar) it always shows in `state`'s
    /// window, which takes it from the window that listed it: a click in one
    /// window never acts in another (Lawrence 2026-10-23).
    /// An action run without view-change permission shows nothing. The window
    /// swaps its content in this turn, not on its observation hop (I6).
    func show(workspaceID: String, in state: WindowState, from origin: ShowOrigin = .anywhere) {
        guard ActionRunScope.viewChangeAllowed() else { return }
        let value = registry.value
        if DebugWorkspaceSwitch.timer.isRecording, let timed = controller(for: value.owner(of: workspaceID) ?? state.id) ?? controller(for: state.id) {
            DebugWorkspaceSwitch.began(timed)
        }
        if origin == .anywhere, let owner = value.owner(of: workspaceID), owner != state.id, value.window(owner)?.isOpen == true,
           let target = controller(for: owner) {
            select(workspaceID, in: target.state)
            target.showWorkspace(requested: target.state.workspaceID)
            bringToFront(target)
            return
        }
        claim(workspaceID: workspaceID, in: state)
        controller(for: state.id)?.showWorkspace(requested: state.workspaceID)
    }

    /// Shows `workspaceID` where it lives: its window when open, else the
    /// active window takes it, else a new window. Returns that window.
    @discardableResult
    /// An action run without view-change permission files the workspace
    /// into a window (the active one, else a new one behind) without
    /// showing it.
    func reveal(workspaceID: String) -> WindowController? {
        let value = registry.value
        let shows = ActionRunScope.viewChangeAllowed()
        if let owner = value.owner(of: workspaceID), value.window(owner)?.isOpen == true, let target = controller(for: owner) {
            if shows { select(workspaceID, in: target.state) }
            return target
        }
        if let active {
            claim(workspaceID: workspaceID, in: active.state, select: shows)
            return active
        }
        return openWindow(workspaces: [workspaceID])
    }

    /// Moves `workspaceID` into `state`'s window and selects it there. Use
    /// for workspaces a window just created (drag to the sidebar, New
    /// Workspace), even before the daemon reports them.
    /// A workspace of an incognito window never moves into a normal one,
    /// nor the reverse: refused with a message.
    /// `select` false files it into the window without showing it
    /// (Option on a drop, or a move this client's user did not start).
    func claim(workspaceID: String, in state: WindowState, select requested: Bool = true) {
        // An action run without view-change permission never shows it.
        let shows = requested && ActionRunScope.viewChangeAllowed()
        if registry.value.crossesIncognito([workspaceID], to: state.id) {
            services.registry.refuse(RefusalStrings.incognitoMismatch)
            return
        }
        protectIfUnknown([workspaceID], window: state.id)
        // Not reported yet: it lands when the daemon reports it, shown only
        // when asked (reconcileMembership).
        if !shows, pendingClaims[workspaceID] != nil { quietClaims.insert(workspaceID) }
        if registry.value.owner(of: workspaceID) == state.id {
            if shows { select(workspaceID, in: state) }
            return
        }
        // A workspace of another room: the window enters that room first, so the selection repair
        // after the move finds it shown there and picks it (Home took a second click otherwise).
        if shows { enterProfile(of: workspaceID, in: state) }
        transition(select: shows ? [state.id: [workspaceID]] : [:]) { $0.move([workspaceID], to: state.id) }
    }

    /// Moves workspaces into an existing window and selects the first there;
    /// a window left without workspaces closes.
    /// Returns false when nothing moved (a move between an incognito
    /// window and a normal one is refused with a message).
    @discardableResult
    func moveWorkspaces(_ ids: [String], toWindow windowID: String, select: Bool = true) -> Bool {
        let select = select && ActionRunScope.viewChangeAllowed()
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
                    incognito: Bool = false, behind: Bool = false) -> WindowController? {
        // A window an action run without view-change permission opens
        // appears behind, never key.
        let behind = behind || !ActionRunScope.viewChangeAllowed()
        let kinds = Set(workspaces.compactMap { registry.value.owner(of: $0) }.map(registry.value.isIncognito))
        if kinds.count > 1 || (incognito && kinds == [false]) {
            services.registry.refuse(RefusalStrings.incognitoMismatch)
            return nil
        }
        if incognito { registry.apply { $0.markIncognito(id); return WindowRegistry.Changes() } }
        if behind { behindWindows.insert(id) }
        protectIfUnknown(workspaces, window: id)
        transition(select: [id: workspaces]) { $0.openWindow(id: id, workspaceIDs: workspaces, frame: frame, behind: behind) }
        guard let controller = controller(for: id) else { return nil }
        if let frame { controller.window?.setFrame(frame, display: true) }
        return controller
    }

    /// Move to New Window's one landing, for every kind of content (tabs, tab groups, panes,
    /// screens, workspaces, workspace groups): `ids` in a new window beside the window they
    /// left (`MovedWindowPlacement`), which takes the focus when `select`. When they are all of
    /// that window's workspaces, the window itself moves there: none opens, none is left empty.
    func openMovedWindow(_ ids: [String], from origin: MoveOrigin, select: Bool) {
        let source = origin.window.flatMap(controller(for:))
        let frame = source?.window.map { MovedWindowPlacement().frame(beside: $0.frame, on: ($0.screen ?? NSScreen.main)?.visibleFrame ?? .infinite) }
        let whole = source.map { Set(ids) == Set(registry.members(of: $0.state.id)) } == true
        if whole, let source, let frame { source.window?.setFrame(frame, display: true); recordSaver.stateDidChange(source.state) }
        guard let moved = whole ? source : openWindow(workspaces: ids, frame: frame, incognito: origin.incognito, behind: !select) else { return }
        if select { bringToFront(moved) }
    }

    /// The user closed window `id`: it stays registered, closed, with its
    /// workspaces, as one closed group (Cmd-Shift-T, History, a Dock click).
    /// A daemon without window records records no group: a non-last window's
    /// workspaces then move to the most recent other window, as before.
    /// An incognito window closes for good: its workspaces close too.
    func userClosed(_ id: String) {
        if restoring || !restored { closedDuringRestore.insert(id) } // the restore must not open it again
        let snapshots = services.sidebarSnapshots
        Task { await snapshots.forget(window: id) }
        let keepsGroup = services.daemon.supports(DaemonCapability.windowRecords.rawValue)
        let changes = transition { $0.close(id, keepsGroup: keepsGroup) }
        discard(changes.discarded)
    }

    /// Reopens the last window after the user closed it (Dock click, Show
    /// cmux). Returns false when no closed window is registered.
    @discardableResult
    func reopenClosedWindow() -> Bool {
        var reopened: String?
        transition { registry in
            reopened = registry.reopen()
            if let reopened { closedDuringRestore.remove(reopened) } // reopened on purpose: the restore keeps it open
            return WindowRegistry.Changes()
        }
        guard let reopened, let controller = controller(for: reopened) else { return false }
        bringToFront(controller)
        return true
    }

    /// Closed window `id`'s group was deleted (`WindowRegistry.releaseClosed`).
    func releaseClosedWindow(id: String) {
        transition { registry in
            let changes = registry.releaseClosed(id)
            // Released with no heir it opens again, on purpose: the restore keeps it open.
            if registry.window(id)?.isOpen == true { closedDuringRestore.remove(id) }
            return changes
        }
        if registry.value.window(id)?.isOpen == true, let controller = controller(for: id) { bringToFront(controller) }
    }

    /// Reopens closed window `id` (Reopen Closed of its `window` group).
    /// False when it is not a closed window of this app.
    @discardableResult
    func reopenClosedWindow(id: String) -> Bool {
        var reopened = false
        transition { registry in
            reopened = registry.reopen(id: id)
            if reopened { closedDuringRestore.remove(id) } // reopened on purpose: the restore keeps it open
            return WindowRegistry.Changes()
        }
        guard reopened, let controller = controller(for: id) else { return false }
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

    /// Re-runs `reconcileMembership` whenever a machine joins, leaves or
    /// loads, the Cloud machine list changes, or a room's rules change. A
    /// loaded machine's workspace set reaches it through the store's
    /// `onWorkspaceListChanged` hook, never through its order: a move or a
    /// group change keeps every window's membership, and this pass visits
    /// every workspace (sidebar churn B).
    func observeMembership() {
        let machines = services.machines
        let cloud = services.cloud
        membershipObservation?.cancel()
        membershipObservation = Task { [weak self] in
            for await _ in ObservationStream({ () -> [String] in
                [String(cloud.hasLoadedMachines), String(cloud.isSignedIn)]
                    + machines.daemons.map { "\($0.machineID):\($0.store.isLoaded)" }
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
        placements.merge(EphemeralWorkspaces.placements(self, live: live, placements: placements)) { claimed, _ in claimed }
        // While an ephemeral workspace is being created here, a new
        // unflagged one of this daemon may be it before its flag arrived:
        // it waits for the create's claim instead of joining a normal window; so does one awaiting its first tab (FirstTabHold).
        let held: Set<String> = FirstTabHold.held(live).union(pendingEphemeralWindows.isEmpty ? [] : live.filter { id in
            registered.owner(of: id) == nil && placements[id] == nil
                && services.machines.workspace(id: id).map { $0.1 === services.daemon } == true
        })
        for id in live where !held.contains(id) { pendingClaims[id] = nil }
        // A claimed workspace is selected in its window, unless it was
        // claimed quietly (`claim(select: false)`).
        let before = registry.value
        var preferred: [String: [String]] = [:]
        for id in live where before.owner(of: id) == nil && !held.contains(id) {
            if let window = placements[id], !quietClaims.contains(id) { preferred[window, default: []].append(id) }
        }
        for id in live where !held.contains(id) { quietClaims.remove(id) }
        let members = before.windows.flatMap(\.workspaceIDs)
        let dead = Set(members.filter(isDead))
        let fallback = launchWindowID ?? closedLaunchWindowID ?? UUID().uuidString.lowercased()
        transition(select: preferred) { registry in
            let changes = registry.reconcile(live: live, dead: dead, placements: placements, held: held, behind: behindWindows,
                                             fallbackWindow: fallback)
            keepClosedDuringRestore(&registry)
            return changes
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
        guard case let cloud = services.cloud, cloud.isSignedIn || cloud.auth.isRestoring else { return true }
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

    /// The room rules (each room's followed sessions, each workspace pin)
    /// and the profile list, so a profile move or a new profile re-runs
    /// reconcile. Not the personal revision: a group change or a placement
    /// bumps it and leaves every window's membership as it was.
    private static func profileTags(of daemon: DaemonService) -> String {
        let personal = daemon.store.personal
        let pins = personal.pins.map { "\($0.sessionID)/\($0.workspaceKey.rawValue)=\($0.profile.rawValue)" }
        let follows = personal.follows.map { "\($0.key.rawValue)>\($0.value.sorted().joined(separator: "+"))" }.sorted()
        return "\(personal.isLoaded)|" + pins.joined(separator: ",") + "|" + follows.joined(separator: ",") + "|"
            + daemon.store.profileIDs.map(\.rawValue).joined(separator: ",")
    }
}

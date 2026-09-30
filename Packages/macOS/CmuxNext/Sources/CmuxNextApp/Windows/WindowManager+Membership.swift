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
        let changes = registry.apply(body)
        if registry.value != before || !preferred.isEmpty { sync(previous: previous, preferred: preferred) }
        return changes
    }

    /// Makes controllers match the registry: closes windows it removed or
    /// closed (animated), opens missing ones, and repairs each window's
    /// selection. Windows whose membership did not change keep their state
    /// untouched.
    func sync(previous: [String: [String]], preferred: [String: [String]] = [:]) {
        let value = registry.value
        for controller in controllers where value.window(controller.state.id)?.isOpen != true {
            closeProgrammatically(controller)
        }
        for id in Array(states.keys) where value.window(id) == nil { states[id] = nil }
        for window in value.openWindows where controller(for: window.id) == nil {
            makeController(for: window)
        }
        for window in value.windows {
            let state = state(for: window.id)
            let pick = WindowRegistry.repairedSelection(current: state.workspaceID, previous: previous[window.id] ?? [],
                                                        members: window.workspaceIDs, preferred: preferred[window.id] ?? [])
            if state.workspaceID != pick { select(pick, in: state) }
        }
        scheduleSave()
    }

    /// Sets the window's shown workspace (its own state).
    func select(_ workspaceID: String?, in state: WindowState) {
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
    func claim(workspaceID: String, in state: WindowState) {
        protectIfUnknown([workspaceID], window: state.id)
        if registry.value.owner(of: workspaceID) == state.id {
            select(workspaceID, in: state)
            return
        }
        transition(select: [state.id: [workspaceID]]) { $0.move([workspaceID], to: state.id) }
    }

    /// Moves workspaces into an existing window and selects the first there.
    func moveWorkspaces(_ ids: [String], toWindow windowID: String, select: Bool = true) {
        guard registry.value.window(windowID)?.isOpen == true, !ids.isEmpty else { return }
        transition(select: select ? [windowID: ids] : [:]) { $0.move(ids, to: windowID) }
    }

    /// Opens a new window listing `workspaces` (taken from their windows,
    /// which close when left empty) and showing the first. Returns its
    /// controller.
    @discardableResult
    func openWindow(id: String = UUID().uuidString.lowercased(), workspaces: [String], frame: CGRect? = nil) -> WindowController? {
        protectIfUnknown(workspaces, window: id)
        transition(select: [id: workspaces]) { $0.openWindow(id: id, workspaceIDs: workspaces, frame: frame) }
        guard let controller = controller(for: id) else { return nil }
        if let frame { controller.window?.setFrame(frame, display: true) }
        return controller
    }

    /// The user closed window `id`: its workspaces move to the most recent
    /// other window; the last window stays registered (restorable).
    func userClosed(_ id: String) {
        transition { $0.close(id) }
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

    /// Closes a window the registry removed. Fades out unless Reduce Motion
    /// is on; never runs the user-close transition.
    func closeProgrammatically(_ controller: WindowController) {
        let id = controller.state.id
        guard !programmaticCloses.contains(id), let window = controller.window else { return }
        programmaticCloses.insert(id)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window.isVisible else {
            window.close()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { window.close() }
        })
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
                    + machines.daemons.map { "\($0.machineID):\($0.store.isLoaded):\(Self.order(of: $0))" }
            }) {
                self?.reconcileMembership()
            }
        }
    }

    func reconcileMembership() {
        var live: [String] = []
        for daemon in services.machines.daemons {
            for id in Self.orderedIDs(of: daemon) {
                live.append(id)
                seenMachine[id] = daemon.machineID
            }
        }
        let placements = pendingClaims
        for id in live { pendingClaims[id] = nil }
        let members = registry.value.windows.flatMap(\.workspaceIDs)
        let dead = Set(members.filter(isDead))
        transition { registry in
            registry.reconcile(live: live, dead: dead, placements: placements, fallbackWindow: UUID().uuidString.lowercased())
        }
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
    static func orderedIDs(of daemon: DaemonService) -> [String] {
        let sidebar = daemon.store.sidebarSections.flatMap(\.workspaces).map(\.id)
        let listed = Set(sidebar)
        return sidebar + daemon.store.workspaces.map(\.id).filter { !listed.contains($0) }
    }

    private static func order(of daemon: DaemonService) -> String {
        orderedIDs(of: daemon).joined(separator: ",")
    }
}

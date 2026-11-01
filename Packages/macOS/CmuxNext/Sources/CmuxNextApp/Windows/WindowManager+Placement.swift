import CmuxNextActions
import CmuxNextBridge
import CmuxNextSidebar
import CmuxNextWakeups

/// A new workspace's sidebar slot, kept until the daemon reports it.
struct PendingPlacement {
    /// The window whose sidebar places it; nil: the window that lists it
    /// once reconcile gave it one (the most recent window).
    var window: String?
    var slot: WorkspaceSlot?
    /// `workspaces.newPlacement`, used when `slot` is nil.
    var byDefault: NewWorkspaceDefaultSlot?
    var then: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)?
    /// The action run that asked for the placement: `then` runs later,
    /// outside its task, and keeps its view-change permission.
    var run: ActionRunScope? = ActionRunScope.current
    /// When the placement first waited for the window's current row (`awaitsCurrentAnchor`): it waits at most
    /// `NewWorkspacePlacements.anchorWaitLimit`, then resolves by the fallback.
    var anchorWaitSince: ContinuousClock.Instant?
}

// Placing new workspaces (New Workspace Above/Below/at Top/Like This, a
// double-click in a group, and `workspaces.newPlacement` for every other new
// workspace): the slot is resolved against the window's sidebar only once
// the daemon reports the workspace, because the reorder plan needs it in the
// daemon's order. It then takes the row-drag path (`SidebarBridge.place`):
// personal order in the home session, else `move-workspace-to-group` on the
// owning daemon.
extension WindowManager {
    /// Retries the placements a cold or updated layout deferred (`awaitsCurrentAnchor`), once a
    /// sidebar rows pass has realized the fresh rows; nothing to do while none waits.
    func retryDeferredPlacements() {
        guard !pendingPlacements.isEmpty else { return }
        applyPendingPlacements(live: Set(pendingPlacements.keys))
    }

    /// One retry once a deferred placement's wait runs out, so it resolves even when no rows pass comes
    /// (`anchorRetry`, a one-shot deadline; a pass that finds one still waiting sets the next).
    private func retryDeferredPlacements(after delay: Duration) {
        anchorRetry.scheduleIfIdle(after: delay) { @MainActor [weak self] in self?.retryDeferredPlacements() }
    }

    func applyPendingPlacements(live: Set<String>) {
        // A placement's rows refresh runs the sidebar's rows pass, whose callback retries deferred
        // placements: a nested call returns at once (no re-entry).
        let rows = PendingWorkspaceRows.shared
        guard !rows.placing else { return }
        rows.placing = true
        defer { rows.placing = false }
        // A placement that waited for its current row was for a workspace the daemon had: once that one is gone (closed,
        // its create undone), nothing will place it.
        for (id, pending) in pendingPlacements where pending.anchorWaitSince != nil && services.machines.workspace(id: id) == nil {
            pendingPlacements[id] = nil
        }
        // A stand-in Cmd-N shows waits: a placement moves a workspace the daemon has.
        let ready = pendingPlacementOrder.filter { live.contains($0) && services.machines.workspace(id: $0)?.0.isProvisional == false }
        // A placement waiting on its current row keeps its entry and its place in the order.
        defer { pendingPlacementOrder.removeAll { pendingPlacements[$0] == nil } }
        var refreshed: Set<String> = []
        for id in ready {
            guard let pending = pendingPlacements[id] else { continue }
            // A rows-pass retry can run before membership names the owner: keep the entry for that pass.
            guard let window = pending.window ?? registry.value.owner(of: id) else { continue }
            // A window the registry still lists whose controller a reconcile has not made yet keeps its entry too.
            guard let bridge = controller(for: window)?.sidebar, let daemon = services.machines.daemon(forWorkspace: id) else {
                if registry.value.window(window) == nil { pendingPlacements[id] = nil }
                continue
            }
            // One store-backed rows pass per window, with this entry still held (its pending row stays at its slot); each
            // following placement reads the model with the preceding optimistic moves applied.
            let sections = Self.placementSections(in: bridge, refresh: refreshed.insert(window).inserted)
            let section = SectionID.machine(MachineID(daemon.machineID))
            let home = NewWorkspacePlacements.home(services.machines)
            let catchingUp = bridge.rows.layoutCatchingUp
            // Waits for a current row this window's cold rows omit. One closed or pinned since the press (it shows in
            // the band, not the list), or one this window does not list (another window's, another space's), has no
            // row to wait for: the rule resolves as if it never had one. So does a wait past its limit.
            var byDefault = pending.byDefault
            if pending.slot == nil, byDefault?.awaitsCurrentAnchor(section: section, in: sections, home: home, catchingUp: catchingUp) == true, let current = byDefault?.current {
                let since = pending.anchorWaitSince ?? .now
                if services.machines.workspace(id: current) != nil,
                   !NewWorkspacePlacements.shownInBand(current, layout: bridge.model.layout, room: bridge.model.activeProfileID?.rawValue,
                                                       legacy: services.sidebarLayout.unavailableReason != nil, machines: services.machines),
                   NewWorkspacePlacements.lists(current, in: window, windows: self),
                   ContinuousClock.now < since + NewWorkspacePlacements.anchorWaitLimit {
                    pendingPlacements[id]?.anchorWaitSince = since
                    retryDeferredPlacements(after: since + NewWorkspacePlacements.anchorWaitLimit - .now)
                    continue
                }
                byDefault?.currentMachine = nil
            }
            pendingPlacements[id] = nil // its move goes to the sidebar now: the next rows pass lists its own row
            // This Mac's daemon placed the workspace by the setting in its create: no second write for that
            // slot. Another machine's create writes no row in this Mac's order, so the app places it. A slot whose anchor is gone takes this fallback.
            let fallback = daemon.isLocal ? byDefault?.move(for: id, section: section, in: sections, home: home, catchingUp: catchingUp)
                : byDefault?.slot(for: id, section: section, in: sections, home: home, catchingUp: catchingUp)
            if let position = pending.slot?.position(moving: [id], section: section, in: sections) ?? fallback?.position(moving: [id], section: section, in: sections) {
                bridge.place([SidebarWorkspaceID(id)], at: position, in: sections)
            }
            ActionRunScope.carrying(pending.run) { pending.then?(id, bridge) }
        }
    }

    /// Slot indices and the reorder plan must use the same current rows. The
    /// daemon can publish several creates before the rows observation runs;
    /// resolving against the last drawn list would put bottom before those rows.
    static func placementSections(in bridge: SidebarBridge, refresh: Bool = true) -> [SidebarRowSection] {
        if refresh { bridge.sameTurn.syncNow(rows: true) }
        return SidebarRowSection.withoutPlaceholders(bridge.model.sections)
    }

    /// Places a workspace this app just made (by a command whose reply
    /// names it) at `slot` of window `windowID` (nil: `workspaces.newPlacement`).
    /// `then` runs after the placement, with the window's sidebar.
    func place(newWorkspace id: String, in windowID: String, at slot: WorkspaceSlot?,
               then: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)? = nil) {
        NewWorkspacePlacements.expect(id, in: windowID, slot: slot, byDefault: slot == nil ? NewWorkspacePlacements.rule(for: windowID, in: self) : nil,
                                      then: then, windows: self)
    }
}

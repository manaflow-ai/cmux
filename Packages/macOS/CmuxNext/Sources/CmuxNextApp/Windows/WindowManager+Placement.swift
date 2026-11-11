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
    /// A drop of a row still being created (`SidebarRowState.creating`; Leo 2026-11-06: "I can only drag them after a
    /// super long time") at `position` of window `window`'s `sections`: its create's slot now (`PendingWorkspaceRow.dropped`),
    /// drawn at once and placed once the daemon lists the workspace. False off its machine section.
    func reslotCreates(_ ids: [String], at position: DropPosition, in window: String, sections: [SidebarRowSection]) -> Bool {
        let rows = PendingWorkspaceRows.shared
        let slots = ids.compactMap { id in rows.rows.first { $0.id == id }?.dropped(at: position, in: sections).map { (id, $0) } }
        guard slots.count == ids.count else { return false }
        for (id, slot) in slots {
            rows.reslot(id, to: slot)
            if pendingPlacements[id] == nil { pendingPlacementOrder.append(id) }
            var pending = pendingPlacements[id] ?? PendingPlacement(window: window, slot: nil, byDefault: nil, then: nil)
            (pending.slot, pending.byDefault, pending.anchorWaitSince) = (slot, nil, nil) // its `then` and run stay
            pendingPlacements[id] = pending
        }
        applyPendingPlacements(live: Set(ids.filter { services.machines.workspace(id: $0) != nil }))
        return true
    }

    func forgetCreate(_ id: String) { pendingPlacements[id] = nil; pendingPlacementOrder.removeAll { $0 == id }; PendingWorkspaceRows.shared.remove(id) } // a create ended without its workspace
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
            NewWorkspacePlacements.forget(id, windows: self)
        }
        // A stand-in Cmd-N shows waits: a placement moves a workspace the daemon has.
        let ready = pendingPlacementOrder.filter { live.contains($0) && services.machines.workspace(id: $0)?.0.isProvisional == false }
        // A placement waiting on its current row keeps its entry and its place in the order.
        defer { pendingPlacementOrder.removeAll { pendingPlacements[$0] == nil } }
        var refreshed: Set<String> = [], placed: Set<String> = []
        for id in ready {
            guard let pending = pendingPlacements[id] else { continue }
            // A rows-pass retry can run before membership names the owner: keep the entry for that pass.
            guard let window = pending.window ?? registry.value.owner(of: id) else { continue }
            // A window the registry still lists whose controller a reconcile has not made yet keeps its entry too.
            guard let bridge = controller(for: window)?.sidebar, let daemon = services.machines.daemon(forWorkspace: id) else {
                if registry.value.window(window) == nil { NewWorkspacePlacements.forget(id, windows: self) }
                continue
            }
            // The daemon placed it beside the window's live current workspace (`placedByDaemon`, before/after current). Top, bottom or none (a page;
            // its top follows its Home row, not the app's) or that one closed mid-create, the app places it as before (`currentGaps`).
            let named = newPlacements.placedByDaemon.contains(id) && pending.byDefault?.placesBesideCurrent == true
                && pending.byDefault?.current.map { services.machines.workspace(id: $0) != nil } == true
            // One store-backed rows pass per window, with this entry still held (its pending row stays at its slot), and another
            // for one whose current row was placed in this pass (rapid Cmd-N): that row's own row lists only from then.
            let sections = Self.placementSections(in: bridge, refresh: refreshed.insert(window).inserted || pending.byDefault?.current.map(placed.contains) == true)
            let section = SectionID.machine(MachineID(daemon.machineID))
            let home = NewWorkspacePlacements.home(services.machines)
            let catchingUp = bridge.rows.layoutCatchingUp
            var byDefault = pending.byDefault
            // A current row still being made (rapid Cmd-N) is placed first; this one then resolves below its slot.
            if pending.slot == nil, let current = byDefault?.current, current != id, pendingPlacements[current] != nil { continue }
            // Waits for a current row cold rows omit (not one closed, pinned or not listed here; nor past the limit). A create
            // this Mac's daemon placed by the window's own rule (`placedByDaemon`) sends no move, so it never waits.
            if pending.slot == nil, !(daemon.isLocal && named),
               byDefault?.awaitsCurrentAnchor(section: section, in: sections, home: home, catchingUp: catchingUp) == true, let current = byDefault?.current {
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
            pendingPlacements[id] = nil; placed.insert(id) // its move goes to the sidebar now: the next rows pass lists its own row
            newPlacements.groupAnchors[id] = nil
            newPlacements.placedByDaemon.remove(id)
            // This Mac's daemon placed the workspace by the setting in its create: no second write for that
            // slot, and none at all when the create named the window's current workspace (`placedByDaemon`).
            // Another machine's create writes no row in this Mac's order, so the app places it. A slot whose anchor is gone takes this fallback.
            let fallback = daemon.isLocal ? (named ? nil : byDefault?.move(for: id, section: section, in: sections, home: home, catchingUp: catchingUp))
                : byDefault?.slot(for: id, section: section, in: sections, home: home, catchingUp: catchingUp)
            print("placement-debug: id \(id) named \(named) local \(daemon.isLocal) byDefault \(String(describing: byDefault)) slot \(String(describing: pending.slot)) fallback \(String(describing: fallback)) home \(String(describing: home)) sections \(sections.map { s in s.nodes.compactMap { n -> String? in if case let .workspace(w) = n { return w.id.rawValue } else { return "*" } } })")
            if let position = pending.slot?.position(moving: [id], section: section, in: sections) ?? fallback?.position(moving: [id], section: section, in: sections) {
                print("placement-debug: place \(id) at \(position)")
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

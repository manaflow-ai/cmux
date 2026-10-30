import CmuxNextActions
import CmuxNextBridge
import CmuxNextSidebar

/// A new workspace's sidebar slot, kept until the daemon reports it.
struct PendingPlacement {
    /// The window whose sidebar places it; nil: the window that lists it
    /// once reconcile gave it one (the most recent window).
    var window: String?
    var slot: WorkspaceSlot?
    /// `workspaces.newPlacement`, used when `slot` is nil.
    var byDefault: NewWorkspaceDefaultSlot?
    var then: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)?
    /// Distinguishes a create that has not reached the daemon yet from a
    /// workspace that was later removed. Failed creates clear their entry;
    /// observed removals can therefore be pruned safely here.
    var hasReported = false
    /// The action run that asked for the placement: `then` runs later,
    /// outside its task, and keeps its view-change permission.
    var run: ActionRunScope? = ActionRunScope.current
}

// Placing new workspaces (New Workspace Above/Below/at Top/Like This, a
// double-click in a group, and `workspaces.newPlacement` for every other new
// workspace): the slot is resolved against the window's sidebar only once
// the daemon reports the workspace, because the reorder plan needs it in the
// daemon's order. It then takes the row-drag path (`SidebarBridge.place`):
// personal order in the home session, else `move-workspace-to-group` on the
// owning daemon.
extension WindowManager {
    /// Cancels an explicit placement when its create operation fails before
    /// the daemon can report the workspace.
    func abandonPendingPlacement(_ id: String) {
        pendingPlacements[id] = nil
    }

    /// Revisit creates whose daemon row arrived before the sidebar projection
    /// did. SidebarBridge calls this after each rendered projection pass, so a
    /// delayed document/order update can complete the original action without
    /// another membership change.
    func retryPendingPlacements() {
        guard !pendingPlacements.isEmpty else { return }
        // This is called from SidebarSameTurn's rows-pass callback. The projection is already
        // current; refreshing rows here would synchronously re-enter that callback.
        applyPendingPlacements(live: Set(pendingPlacements.keys), refreshRows: false)
    }

    func applyPendingPlacements(live: Set<String>, refreshRows: Bool = true) {
        // A stand-in Cmd-N shows waits: a placement moves a workspace the daemon has.
        let removed = pendingPlacements.compactMap { id, pending in
            pending.hasReported && services.machines.workspace(id: id) == nil ? id : nil
        }
        for id in removed {
            pendingPlacements[id] = nil
            pendingPlacementOrder.removeAll { $0 == id }
        }
        pendingPlacementOrder.removeAll { pendingPlacements[$0] == nil }
        let ready = pendingPlacementOrder.filter { live.contains($0) && services.machines.workspace(id: $0)?.0.isProvisional == false }
        var refreshed: Set<String> = []
        for id in ready {
            guard let pending = pendingPlacements[id] else { continue }
            guard let workspace = services.machines.workspace(id: id) else {
                // Before the create reply, retain the placement; the create
                // failure path removes it explicitly. Once the daemon has
                // reported it, an absent workspace is a confirmed removal.
                if pending.hasReported {
                    pendingPlacements[id] = nil
                    pendingPlacementOrder.removeAll { $0 == id }
                }
                continue
            }
            guard workspace.0.isProvisional != true else { continue }
            pendingPlacements[id]?.hasReported = true
            if let requestedWindow = pending.window {
                let target = registry.value.window(requestedWindow)
                if target?.isOpen == false || (target == nil && pendingClaims[id] != requestedWindow) {
                    pendingPlacements[id] = nil
                    pendingPlacementOrder.removeAll { $0 == id }
                    continue
                }
            }
            guard let window = pending.window ?? registry.value.owner(of: id), let bridge = controller(for: window)?.sidebar,
                  let daemon = services.machines.daemon(forWorkspace: id) else { continue }
            // One store-backed rows pass per window; each following placement
            // reads the model with the preceding optimistic moves applied.
            let sections = Self.placementSections(in: bridge, refresh: refreshRows && refreshed.insert(window).inserted)
            // A synchronous rows refresh may have retried and consumed this entry already.
            guard pendingPlacements[id] != nil else { continue }
            let section = SectionID.machine(MachineID(daemon.machineID))
            let home = NewWorkspacePlacements.home(services.machines)
            // The daemon can report a created workspace before this window's
            // projection has materialized its row. Retain the pending rule so
            // the next reconcile can resolve the slot instead of silently
            // losing Bottom/legacy Top placement.
            // A document can list a workspace in a custom section instead of the machine section.
            // Its row being present is enough to finish the create callback; only a row that has
            // not reached any projection should remain pending.
            guard sections.contains(where: { NewWorkspaceDefaultSlot.position(of: id, in: $0.id, sections: sections) != nil }) else { continue }
            // This Mac's daemon placed the workspace by the setting in its create: no second write for that
            // slot. Another machine's create writes no row in this Mac's order, so the app places it.
            let slot = pending.slot ?? (daemon.isLocal ? pending.byDefault?.move(for: id, section: section, in: sections, home: home)
                : pending.byDefault?.slot(for: id, section: section, in: sections, home: home))
            pendingPlacements[id] = nil
            pendingPlacementOrder.removeAll { $0 == id }
            if let position = slot?.position(moving: [id], section: section, in: sections) {
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

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
    func applyPendingPlacements(live: Set<String>) {
        // A stand-in Cmd-N shows waits: a placement moves a workspace the daemon has.
        for (id, pending) in pendingPlacements where live.contains(id) && services.machines.workspace(id: id)?.0.isProvisional != true {
            pendingPlacements[id] = nil
            guard let window = pending.window ?? registry.value.owner(of: id), let bridge = controller(for: window)?.sidebar,
                  let daemon = services.machines.daemon(forWorkspace: id) else { continue }
            let sections = SidebarRowSection.withoutPlaceholders(bridge.model.sections)
            let section = SectionID.machine(MachineID(daemon.machineID))
            let home = NewWorkspacePlacements.home(services.machines)
            // This Mac's daemon placed the workspace by the setting in its create: no second write for that
            // slot. Another machine's create writes no row in this Mac's order, so the app places it.
            let slot = pending.slot ?? (daemon.isLocal ? pending.byDefault?.move(for: id, section: section, in: sections, home: home)
                : pending.byDefault?.slot(for: id, section: section, in: sections, home: home))
            if let position = slot?.position(moving: [id], section: section, in: sections) {
                bridge.place([SidebarWorkspaceID(id)], at: position, in: sections)
            }
            ActionRunScope.carrying(pending.run) { pending.then?(id, bridge) }
        }
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

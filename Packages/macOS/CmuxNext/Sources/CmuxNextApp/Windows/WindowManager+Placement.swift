import CmuxNextActions
import CmuxNextBridge
import CmuxNextSidebar

/// A new workspace's sidebar slot, kept until the daemon reports it.
struct PendingPlacement {
    var window: String
    var slot: WorkspaceSlot?
    var then: (@MainActor @Sendable (String, SidebarBridge) -> Void)?
    /// The action run that asked for the placement: `then` runs later,
    /// outside its task, and keeps its view-change permission.
    var run: ActionRunScope? = ActionRunScope.current
}

// Placing new workspaces (New Workspace Above/Below/at Top/in This Group, a
// double-click in a group): the slot is resolved against the window's
// sidebar only once the daemon reports the workspace, because the reorder
// plan needs it in the daemon's order. It then takes the row-drag path
// (`SidebarBridge.place`): personal order in the home session, else
// `move-workspace-to-group` on the owning daemon.
extension WindowManager {
    func applyPendingPlacements(live: Set<String>) {
        for (id, pending) in pendingPlacements where live.contains(id) {
            pendingPlacements[id] = nil
            guard let bridge = controller(for: pending.window)?.sidebar,
                  let machine = services.machines.daemon(forWorkspace: id)?.machineID else { continue }
            let sections = bridge.model.sections
            let section = SectionID.machine(MachineID(machine))
            if let position = pending.slot?.position(moving: [id], section: section, in: sections) {
                bridge.place([SidebarWorkspaceID(id)], at: position, in: sections)
            }
            ViewChangePolicy.carrying(pending.run) { pending.then?(id, bridge) }
        }
    }

    /// Places a workspace this app just made (by a command whose reply
    /// names it) at `slot` of window `windowID`: now when it is mirrored,
    /// else once the daemon reports it.
    /// `then` runs after the placement, with the window's sidebar.
    func place(newWorkspace id: String, in windowID: String, at slot: WorkspaceSlot?,
               then: (@MainActor @Sendable (String, SidebarBridge) -> Void)? = nil) {
        pendingPlacements[id] = PendingPlacement(window: windowID, slot: slot, then: then)
        if services.machines.workspace(id: id) != nil { applyPendingPlacements(live: [id]) }
    }
}

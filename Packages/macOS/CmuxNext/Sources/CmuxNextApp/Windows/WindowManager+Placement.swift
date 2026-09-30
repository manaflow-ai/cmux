import CmuxNextBridge
import CmuxNextSidebar

/// A new workspace's sidebar slot, kept until the daemon reports it.
struct PendingPlacement: Hashable, Sendable {
    var window: String
    var slot: WorkspaceSlot
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
            guard let position = pending.slot.position(moving: [id], section: section, in: sections) else { continue }
            bridge.place([SidebarWorkspaceID(id)], at: position, in: sections)
        }
    }
}

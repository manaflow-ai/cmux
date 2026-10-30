import AppKit
import CmuxNextLayout

// Parked workspaces (plans/cmux-next/tab-lifecycle.md): every workspace this window showed stays mounted and
// paused, so a switch back swaps its view in within the frame.
extension WindowController {
    /// The shown workspace, then the parked ones from the most recently shown, each with its theme scope.
    var mountedContents: [WorkspaceContentController] {
        (content.map { [$0] } ?? []) + parked.values.sorted { $0.parkedSerial > $1.parkedSerial }
    }

    /// Critical memory pressure: the parked workspaces leave (views, panes, observations; their
    /// terminal surfaces already left the warm set) and mount again when shown, with their
    /// view-only state (strip and screen bar scroll) reset. The one under a top page stays: it is
    /// this window's workspace. So do the ones on screen beside the shown one (`sidebar.multiView`).
    func releaseParked() {
        for (id, controller) in parked where (content != nil || id != state.workspaceID) && !isOnScreenBeside(id) {
            parked[id] = nil
            controller.teardown()
        }
    }

    /// Workspace `id` hibernated (plans/cmux-next/workspace-hibernation-DESIGN.md): its parked content
    /// leaves (views, panes, observations) and mounts again, cold, when shown. Never the shown
    /// workspace, the one under a top page or one on screen beside it.
    func releaseParked(_ id: String) {
        guard id != state.workspaceID, !isOnScreenBeside(id), let controller = parked.removeValue(forKey: id) else { return }
        controller.teardown()
    }

    /// On screen beside the shown workspace: in the `sidebar.multiView` set, a shown docked workspace or the stage's
    /// workspace while a dock has the focus (`window.dockedWorkspaces`).
    func isOnScreenBeside(_ id: String) -> Bool {
        state.isOnScreenBeside(id)
    }

    func park(_ controller: WorkspaceContentController) {
        parkSerial &+= 1
        controller.park(serial: parkSerial)
        parked[controller.workspace.id] = controller
    }
}

import AppKit
import CmuxNextBridge
import CmuxNextLayout

// Parked workspaces (plans/cmux-next/tab-lifecycle.md): the workspaces this window showed most recently stay
// mounted and paused (`ParkedWorkspaceBudget`), so a switch back swaps its view in within the frame.
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
        for (id, controller) in parked where !keepsParked(id) {
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

    /// Parks `controller`; past the budget the oldest leave, never `controller` itself (a page may cover it).
    /// `leaving` is the workspace about to show: `show` takes it out next, so it neither counts nor leaves.
    func park(_ controller: WorkspaceContentController, leaving: String? = nil) {
        parkSerial &+= 1
        controller.park(serial: parkSerial)
        parked[controller.workspace.id] = controller
        trimParked(keeping: controller.workspace.id, leaving: leaving)
    }

    /// Past `ParkedWorkspaceBudget.standard`'s capacity, the least recently parked workspaces leave as under
    /// critical pressure, so a window that visited hundreds keeps a bounded set mounted.
    private func trimParked(keeping parkedNow: String, leaving: String?) {
        let budget = ParkedWorkspaceBudget.standard
        let entries = parked.compactMap { $0.key == leaving ? nil : (id: $0.key, serial: $0.value.parkedSerial) }
        guard entries.count > budget.capacity else { return }
        let kept = Set(parked.keys.filter(keepsParked)).union([parkedNow])
        for id in budget.evictions(parked: entries, kept: kept) {
            parked.removeValue(forKey: id)?.teardown()
        }
    }

    /// The one under a top page (this window's workspace) and the ones on screen beside the shown one (multi-view, docks).
    private func keepsParked(_ id: String) -> Bool {
        (content == nil && id == state.workspaceID) || isOnScreenBeside(id)
    }
}

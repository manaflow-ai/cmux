import AppKit
import CmuxNextBridge

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

    func park(_ controller: WorkspaceContentController) {
        parkSerial &+= 1
        controller.park(serial: parkSerial)
        parked[controller.workspace.id] = controller
        trimParked()
    }

    /// Past `ParkedWorkspaceBudget.standard`'s capacity, the least recently parked workspaces leave as under
    /// critical pressure, so a window that visited hundreds keeps a bounded set mounted.
    private func trimParked() {
        let budget = ParkedWorkspaceBudget.standard
        guard parked.count > budget.capacity else { return }
        let entries = parked.map { (id: $0.key, serial: $0.value.parkedSerial) }
        let kept = Set(parked.keys.filter(keepsParked))
        for id in budget.evictions(parked: entries, kept: kept) {
            parked.removeValue(forKey: id)?.teardown()
        }
    }

    /// The one under a top page (this window's workspace) and the ones on screen beside the shown one.
    private func keepsParked(_ id: String) -> Bool {
        (content == nil && id == state.workspaceID) || state.viewSet?.contains(id) == true
    }
}

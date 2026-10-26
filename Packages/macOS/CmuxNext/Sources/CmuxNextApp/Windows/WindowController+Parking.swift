import AppKit
import CmuxNextHibernation

// Parked workspaces (plans/cmux-next/tab-lifecycle.md): a workspace this window showed stays mounted and
// paused, so a switch back swaps its view in within the frame. With `memoryDiscardParkedWorkspaces` (default
// off) the app's `ParkedWorkspaceBudget` holds them, across every window, to the Mac's budget and idle timeout;
// off, every one stays until critical memory pressure.
extension WindowController {
    /// The shown workspace, then the parked ones from the most recently shown, each with its theme scope.
    var mountedContents: [WorkspaceContentController] {
        (content.map { [$0] } ?? []) + parked.values.sorted { $0.parkedSerial > $1.parkedSerial }
    }

    /// Critical memory pressure without the parked budget: the parked workspaces leave (views, panes,
    /// observations; their terminal surfaces already left the warm set) and mount again when shown, as they
    /// were: each leaves its `WorkspaceViewRecord` (strip, row, area, tab strip and screen bar scrolls), which
    /// the mount applies before its first frame; its tab selections and focused pane stay in this window's
    /// memory. The ones the window keeps stay (``keepsParkedWorkspace(_:)``). With the budget, its memory
    /// consumer releases them one per slice.
    func releaseParked() {
        for id in Array(parked.keys) where !keepsParkedWorkspace(id) { discardParkedWorkspace(id) }
    }

    func park(_ controller: WorkspaceContentController) {
        parkSerial &+= 1
        controller.park(serial: parkSerial)
        parked[controller.workspace.id] = controller
        services.parkedWorkspaceBudget?.didPark(controller.workspace.id, in: self)
    }

    /// Takes parked workspace `id` out of the window (to show it, or to tear it down) and out of the budget.
    func unpark(_ id: String) -> WorkspaceContentController? {
        services.parkedWorkspaceBudget?.forget(id, in: self)
        return parked.removeValue(forKey: id)
    }
}

extension WindowController: ParkedWorkspaceHolder {
    /// The window's own workspace under a top page stays (it is this window's workspace), and so do
    /// the ones on screen beside the shown one (`sidebar.multiView`).
    func keepsParkedWorkspace(_ id: String) -> Bool {
        (content == nil && id == state.workspaceID) || state.viewSet?.contains(id) == true
    }

    @discardableResult
    func discardParkedWorkspace(_ id: String) -> Bool {
        guard let controller = unpark(id) else { return false }
        unmountedViews[id] = controller.viewRecord()
        controller.teardown()
        return true
    }
}

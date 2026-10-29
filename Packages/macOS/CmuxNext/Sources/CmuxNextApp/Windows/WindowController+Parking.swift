import AppKit
import CmuxNextHibernation
import CmuxNextLayout

// Parked workspaces (plans/cmux-next/tab-lifecycle.md): a workspace this window showed stays mounted and
// paused, so a switch back swaps its view in within the frame. The app's `ParkedWorkspaceBudget` follows them
// across every window: critical memory pressure tears them down one per release slice, and with
// `memoryDiscardParkedWorkspaces` (default off) it holds them to the Mac's budget and idle timeout.
extension WindowController {
    /// The shown workspace, then the parked ones from the most recently shown, each with its theme scope.
    var mountedContents: [WorkspaceContentController] {
        (content.map { [$0] } ?? []) + parked.values.sorted { $0.parkedSerial > $1.parkedSerial }
    }

    /// Workspace `id` hibernated (plans/cmux-next/workspace-hibernation-DESIGN.md): its parked content
    /// leaves (views, panes, observations) and mounts again, cold, when shown. Never the shown
    /// workspace, the one under a top page or one on screen beside it.
    func releaseParked(_ id: String) {
        guard id != state.workspaceID, !isOnScreenBeside(id), parked[id] != nil, let controller = unpark(id) else { return }
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
        services.parkedWorkspaceBudget.didPark(controller.workspace.id, in: self)
    }

    /// Takes parked workspace `id` out of the window (to show it, or to tear it down) and out of the budget.
    func unpark(_ id: String) -> WorkspaceContentController? {
        services.parkedWorkspaceBudget.forget(id, in: self)
        return parked.removeValue(forKey: id)
    }
}

extension WindowController: ParkedWorkspaceHolder {
    /// Shown, not minimized and not fully covered.
    var showsOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// The window's own workspace under a top page stays (it is this window's workspace), and so do
    /// the ones on screen beside the shown one (`sidebar.multiView`, a docked workspace or the stage's).
    func keepsParkedWorkspace(_ id: String) -> Bool {
        (content == nil && id == state.workspaceID) || isOnScreenBeside(id)
    }

    /// Tears the workspace down (views, panes, observations); it mounts again when shown, as it was: it
    /// leaves its `WorkspaceViewRecord` (strip, row, area, tab strip and screen bar scrolls), which the mount
    /// applies before its first frame; its tab selections and focused pane stay in this window's memory.
    @discardableResult
    func discardParkedWorkspace(_ id: String) -> Bool {
        guard let controller = unpark(id) else { return false }
        unmountedViews[id] = controller.viewRecord()
        controller.teardown()
        return true
    }
}

import CmuxAppKitSupportUI
import CmuxSidebar

@MainActor
extension SidebarDragAutoScrollController {
    /// Claims the process-wide reorder lease before starting this controller.
    func updateForWorkspaceReorder(dragState: SidebarDragState) {
        guard dragState.claimWorkspaceDragAutoscroll(relinquish: { [weak self] in
            self?.stop()
        }) else {
            stop()
            return
        }
        updateFromDragLocation()
    }

    /// Releases the process-wide reorder lease and stops this controller.
    func stopForWorkspaceReorder(dragState: SidebarDragState) {
        dragState.stopWorkspaceDragAutoscroll()
        stop()
    }
}

public import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Shown or not (recipe R-hide, plans/cmux-next/main-thread-budget.md section 11): AppKit's hide hooks
/// only tell the view's ``visibilityNode``, and the node's flips (the view hidden or shown, its tab
/// selected or not, its pane suspended, its workspace parked, its window minimized, the app hidden) all
/// reach ``syncWindowState()`` through its subscription. Nothing walks the ancestors for hidden state.
/// An occluded window keeps its terminals shown: they keep their layout ready and their own occlusion
/// watch pauses the drawing (``Visibility/occluded``).
extension TerminalSurfaceView {
    public override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
    }

    /// Shown in a window: observe it and apply its current scale, screen, size, occlusion and key
    /// state (each a no-op when unchanged). Parked counts as hidden (``ParkingContainer``): a container
    /// tells its observers when it parks, and a hidden terminal re-checks parking when its node shows.
    func syncWindowState() {
        let shown = window != nil && visibilityNode.effective > .hidden && !isParkedOrHasParkedAncestor
        isShown = shown
        observeWindow(shown)
        // A hidden terminal gets no mouseExited: its link hover and modifier watcher end here.
        if !shown { linkPointer.exited() }
        if shown {
            updateContentScale()
            // A view that joins a pane on a layout spring sends the grid the spring rests at, once; its first
            // report (held while it was not shown) would be a size no frame rests at.
            let joined = isInPaneMotion && joinPaneMotion()
            updateSurfaceSize(forceReport: pendingForcedReport && !joined)
            pendingForcedReport = false
        }
        updateOcclusion()
        updateFocus()
    }
}

public import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Shown or not (recipe R-hide, plans/cmux-next/main-thread-budget.md section 11): AppKit's hide hooks
/// only tell the view's ``visibilityNode``, and the window and parking checks only set its child
/// ``windowNode``. The flips of that child (the view hidden or shown, its tab selected or not, its pane
/// suspended, its workspace parked, its window minimized or left, the app hidden) all reach
/// ``syncWindowState()`` through its subscription, and the size and scale work a terminal skipped while it
/// was not shown waits on it under a key (``DeferredWork``), so a show runs each once. Nothing walks the
/// ancestors for hidden state. An occluded window keeps its terminals shown: they keep their layout ready
/// and their own occlusion watch pauses the drawing (``Visibility/occluded``).
extension TerminalSurfaceView {
    public override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
    }

    /// In a window and no container above parked (``ParkingContainer``): read when the view changes windows,
    /// when a container above tells its observers it parked, and when ``visibilityNode`` shows.
    func syncPlacement() {
        windowNode.set(window != nil && !isParkedOrHasParkedAncestor ? .visible : .hidden)
    }

    /// Shown in a window: observe it and apply its current scale, screen, occlusion and key state (each a
    /// no-op when unchanged). The size it owes runs next, from ``windowNode``'s deferred work.
    func syncWindowState() {
        let shown = isShown
        observeWindow(shown)
        // A hidden terminal gets no mouseExited: its link hover and modifier watcher end here.
        if shown { updateContentScale() } else { linkPointer.exited() }
        updateOcclusion()
        updateFocus()
    }
}

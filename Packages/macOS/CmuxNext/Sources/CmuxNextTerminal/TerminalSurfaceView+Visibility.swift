public import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Shown or not (recipe R-hide, plans/cmux-next/main-thread-budget.md section 11): AppKit's hide hooks
/// only tell the view's ``visibilityNode``, and the window and parking checks only set its child
/// ``windowNode``. The flips of that child (the view hidden or shown, its tab selected or not, its pane
/// suspended, its workspace parked, its window minimized or left, the app hidden) all reach
/// ``syncWindowState()`` through its subscription. A terminal that is not shown does no size or scale work;
/// the edge to shown reconciles both from its current bounds and window, once (``reconcileShown()``). Nothing
/// walks the ancestors for hidden state. An occluded window keeps its terminals shown: they keep their layout ready
/// and their own occlusion watch pauses the drawing (``Visibility/occluded``).
extension TerminalSurfaceView {
    // The draw pause reads AppKit's own hidden state (``WindowDrawPolicy/inputs(for:suspended:forced:)``), not the
    // node, so AppKit's hide and unhide recompute it here (a no-op when it did not change). A node flip alone did
    // not: a surface that joined an already hidden container never got viewDidHide, its node stayed visible, and
    // the container's unhide left it paused `hidden` with nothing hidden (v2.2.5-opt, a second tab beside Home).
    // visibility-walk-allow: the draw pause reads AppKit's hidden state (WindowDrawPolicy.inputs, itself allowed), so AppKit's hide transition recomputes it; transitions only, never per frame
    public override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
        updateOcclusion()
    }

    // visibility-walk-allow: the draw pause reads AppKit's hidden state (WindowDrawPolicy.inputs, itself allowed), so AppKit's unhide transition recomputes it; transitions only, never per frame
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
        updateOcclusion()
    }

    /// In a window and no container above parked (``ParkingContainer``): read when the view changes windows,
    /// when a container above tells its observers it parked, and when ``visibilityNode`` shows.
    func syncPlacement() {
        windowNode.set(window != nil && !isParkedOrHasParkedAncestor ? .visible : .hidden)
    }

    /// Shown in a window: observe it and apply its current occlusion and key state and the cursor layer's
    /// shown state (each a no-op when unchanged), then its scale and size from its window and bounds
    /// (``reconcileShown()``).
    func syncWindowState() {
        let shown = isShown
        cursorLayer?.setShown(shown) // the cursor's blink runs only while the terminal shows
        observeWindow(shown)
        // A hidden terminal gets no mouseExited: its link hover and modifier watcher end here.
        if !shown { linkPointer.exited() }
        updateOcclusion()
        updateFocus()
        // The edge to shown only: a flip between visible and occluded keeps the layout ready (it sized all along).
        if shown, !reconciledShown { reconcileShown() }
        reconciledShown = shown
    }
}

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

    /// The surface or a container above it moved within its window (``TerminalHostView``'s move, the surface's own
    /// move between hosts): a reparent can change AppKit's hidden state with no hide, unhide or window move. The
    /// node takes it as viewDidHide/viewDidUnhide would have given it (a flip runs ``syncWindowState()``: shown
    /// work, watches, the pause), and the draw pause, which reads AppKit's state, is computed again (a no-op when
    /// nothing changed). Transitions only.
    func ancestorsMoved() {
        // visibility-walk-allow: a reparent is a transition AppKit may report with no hide or unhide; the node takes AppKit's state once per move, never per frame
        visibilityNode.set(isHiddenOrHasHiddenAncestor ? .hidden : .visible)
        updateOcclusion()
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        ancestorsMoved()
    }

    /// In a window and no container above parked (``ParkingContainer``): read when the view changes windows,
    /// when a container above tells its observers it parked, and when ``visibilityNode`` shows.
    func syncPlacement() {
        windowNode.set(window != nil && !isParkedOrHasParkedAncestor ? .visible : .hidden)
    }

    /// Shown in a window: observe it and apply its current scale, screen, occlusion and key state, and the cursor
    /// layer's shown state (each a no-op when unchanged). The size it owes runs next, from ``windowNode``'s deferred work.
    func syncWindowState() {
        let shown = isShown
        cursorLayer?.setShown(shown) // the cursor's blink runs only while the terminal shows
        observeWindow(shown)
        // A hidden terminal gets no mouseExited: its link hover and modifier watcher end here.
        if shown { updateContentScale() } else { linkPointer.exited() }
        updateOcclusion()
        updateFocus()
    }
}

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

extension TerminalSurfaceView {
    /// The window node and every node above it, "name own/effective" (``TerminalSurfaceDiagnostics/nodeChain``).
    /// A chain that ends before a window's node (a detached tab node) shows why a terminal is never shown.
    var nodeChain: [String] {
        var chain: [String] = []
        var node: VisibilityNode? = windowNode
        while let current = node, chain.count < 16 {
            chain.append("\(current.name) \(current.own)/\(current.effective)")
            node = current.parent
        }
        return chain
    }
}

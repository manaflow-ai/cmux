public import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Shown or not (recipe R-hide, plans/cmux-next/main-thread-budget.md section 11): AppKit's hide hooks
/// only tell the view's ``visibilityNode``, and the window and parking checks only set its child
/// ``windowNode``. The flips of that child (the view hidden or shown, its tab selected or not, its pane
/// suspended, its workspace parked, its window left) all reach
/// ``syncWindowState()`` through its subscription. A terminal that is not shown does no size or scale work;
/// the edge to shown reconciles both from its current bounds and window, once (``reconcileShown()``). Only a move
/// reads AppKit's hidden state (below). An occluded or minimized window keeps its terminals shown: they keep their
/// layout ready and the watch of their window's node pauses the drawing (``watchWindowNode(of:)``).
///
/// The node's own state is AppKit's hidden state, given at each AppKit edge that can change it: a hide, an unhide,
/// and a move (into a window, under another superview, or the host moved within its window: ``ancestorsMoved()``), so
/// a surface that joins an already hidden container, or leaves one with no unhide, still has the true state. The draw
/// pause reads only the nodes (TerminalSurfaceView+Occlusion.swift).
extension TerminalSurfaceView {
    public override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        ancestorsMoved()
    }

    /// The surface or a container above it moved (into a window, between hosts, or its host within its window): a
    /// move can change AppKit's hidden state with no hide or unhide. The node takes it, as a hide or unhide would
    /// have given it; a flip runs ``syncWindowState()`` (the pause, shown work, watches). Transitions only.
    func ancestorsMoved() {
        // visibility-walk-allow: a move is an AppKit edge with no hide or unhide; the node takes AppKit's state once per move, never per frame
        visibilityNode.set(isHiddenOrHasHiddenAncestor ? .hidden : .visible)
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

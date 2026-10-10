public import AppKit
import CmuxNextDesign
import QuartzCore

/// Tab drops: the in-process drag API for tab strips that track the mouse
/// themselves, and the AppKit `NSDraggingDestination` path.
extension LayoutRootView {
    /// Updates the drop highlight for an in-process tab drag (for tab strips
    /// that track the mouse themselves instead of using NSDraggingSession).
    /// `removing` is the pane the drag empties: the split room is decided
    /// here once, with it, and the commit runs this decision. `edgeDwell`: a
    /// pane edge splits only after the pointer has stayed on it this long;
    /// before that it joins the pane (cmuxterm-hq#1829: eager split targets).
    @discardableResult
    public func updateTabDrag(_ tab: TabID, locationInWindow: NSPoint, removing: PaneID? = nil,
                              edgeDwell: CFTimeInterval = 0) -> DropTarget? {
        dragTab = tab
        tabDragRemoving = removing
        guard let active = model.activeScreenID, let view = screenViews[active] else {
            hideHighlight()
            return nil
        }
        let local = view.convert(locationInWindow, from: nil)
        guard var hit = view.dropTarget(at: local, removing: removing, previous: tabDropHit) else {
            hideHighlight()
            return nil
        }
        tabDragDwellDeadline = nil
        if edgeDwell > 0, case let .pane(_, zone) = hit.hit, zone != .center {
            let now = CACurrentMediaTime()
            if tabDragEdge?.hit != hit.hit { tabDragEdge = (hit.hit, now) }
            let deadline = (tabDragEdge?.since ?? now) + edgeDwell
            if now < deadline, let held = view.dropTarget(at: local, removing: removing, previous: tabDropHit, edgesArmed: false) {
                hit = held
                tabDragDwellDeadline = deadline
            }
        } else {
            tabDragEdge = nil
        }
        tabDropHit = hit.hit
        let rect = convert(hit.highlight, from: view)
        let region = convert(hit.region, from: view)
        tabDragHighlightOnScreen = window.map { $0.convertToScreen(convert(rect, to: nil)) }
        let style = context.style
        // Pane zones trace the rounded pane rect (already inset by the
        // padding); without pane chrome the highlight floats inside the pane.
        let traces = style.hasPaneChrome && hit.target.isPaneZone
        let tunedRadius = CGFloat(DropOverlayTunables.cornerRadius.value)
        let radius = tunedRadius >= 0 ? tunedRadius
            : traces ? PaneChromeGeometry.cornerRadius(for: rect, style: style) : style.panelCornerRadius
        let inset = traces ? 0 : DropOverlayTunables.floatingInset.resolve(Metrics.space2)
        if highlight.show(rect, region: region, zone: DropOverlayZone(hit.target), text: LayoutStrings.label(for: hit.target),
                          inset: inset, cornerRadius: radius, pointer: convert(locationInWindow, from: nil),
                          animated: canAnimate) { driver.start() }
        return hit.target
    }

    /// Shows the drop outline on `screenRect` (a tab strip's insert slot):
    /// the same overlay as the pane zones, so the outline moves between
    /// them. Nothing is hit-tested; the strip owns that target.
    public func showTabDragOutline(screenRect: CGRect) {
        guard let window else { return }
        let rect = convert(window.convertFromScreen(screenRect), from: nil)
        tabDragHighlightOnScreen = screenRect
        tabDropHit = nil
        let radius = min(context.style.panelCornerRadius, rect.height / 2)
        if highlight.show(rect, region: rect, zone: .center, text: "", inset: 0, cornerRadius: radius,
                          pointer: CGPoint(x: rect.midX, y: rect.midY), animated: canAnimate) { driver.start() }
    }

    /// Hides the drop highlight `updateTabDrag` showed, for a zone the App
    /// refuses: it draws nothing. The drag goes on, and the zone held near
    /// its line stays for the next hit test.
    public func hideTabDragHighlight() {
        tabDragHighlightOnScreen = nil
        if highlight.hide(animated: false) { driver.start() }
    }

    /// Labels the current drop preview with why a drop there is refused
    /// (`refused`), or that it keeps the tabs in place. Call after
    /// `updateTabDrag`; the next update shows the target's own label again.
    public func setTabDragNote(_ text: String, refused: Bool) {
        highlight.setNote(text, refused: refused)
    }

    /// Ends a tab drag. Emits `.dropTab` when over a target and returns it.
    /// The drop resolves with the pane the preview's split room was decided
    /// with, so it lands where the ring shows (cx-ohle).
    @discardableResult
    public func endTabDrag(_ tab: TabID, locationInWindow: NSPoint) -> DropTarget? {
        let target = updateTabDrag(tab, locationInWindow: locationInWindow, removing: tabDragRemoving)
        hideHighlight()
        dragTab = nil
        tabDragRemoving = nil
        if let target { model.dropTab(tab, on: target) }
        return target
    }

    public func cancelTabDrag() {
        dragTab = nil
        tabDragRemoving = nil
        hideHighlight()
    }

    func hideHighlight() {
        tabDragHighlightOnScreen = nil
        tabDropHit = nil
        tabDragEdge = nil
        tabDragDwellDeadline = nil
        if highlight.hide(animated: canAnimate) { driver.start() }
    }

    // MARK: NSDraggingDestination

    private func tabID(from info: any NSDraggingInfo) -> TabID? {
        info.draggingPasteboard.string(forType: LayoutTabDrag.pasteboardType).map(TabID.init(rawValue:))
    }

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let tab = tabID(from: sender), updateTabDrag(tab, locationInWindow: sender.draggingLocation) != nil else {
            hideHighlight()
            return []
        }
        return .move
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        cancelTabDrag()
    }

    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let tab = tabID(from: sender) else { return false }
        return endTabDrag(tab, locationInWindow: sender.draggingLocation) != nil
    }

    override public func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        cancelTabDrag()
    }
}

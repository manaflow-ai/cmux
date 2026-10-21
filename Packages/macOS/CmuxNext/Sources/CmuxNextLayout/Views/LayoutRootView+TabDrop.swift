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
    /// `joinsFrom`: the source pane of a terminal tab; the edge of the pane
    /// next to it that faces it joins that pane (bonsplit, #22287).
    @discardableResult
    public func updateTabDrag(_ tab: TabID, locationInWindow: NSPoint, removing: PaneID? = nil,
                              joinsFrom: PaneID? = nil, edgeDwell: CFTimeInterval = 0) -> DropTarget? {
        dragTab = tab
        tabDragRemoving = removing
        tabDragJoinsFrom = joinsFrom
        guard let active = model.activeScreenID, let view = screenViews[active] else {
            hideHighlight()
            return nil
        }
        let local = view.convert(locationInWindow, from: nil)
        guard var hit = view.dropTarget(at: local, removing: removing, joinsFrom: joinsFrom, previous: tabDropHit) else {
            hideHighlight()
            return nil
        }
        tabDragDwellDeadline = nil
        if edgeDwell > 0, case let .pane(_, zone) = hit.hit, zone != .center {
            let now = CACurrentMediaTime()
            if tabDragEdge?.hit != hit.hit { tabDragEdge = (hit.hit, now) }
            let deadline = (tabDragEdge?.since ?? now) + edgeDwell
            if now < deadline, let held = view.dropTarget(at: local, removing: removing, joinsFrom: joinsFrom, previous: tabDropHit,
                                                                   edgesArmed: false) {
                hit = held
                tabDragDwellDeadline = deadline
            }
        } else {
            tabDragEdge = nil
        }
        tabDropHit = hit.hit
        tabDragShownTarget = hit.target
        // The App refused this target at the last move: it stays hidden, nothing redraws (a flicker).
        guard hit.target != tabDragRefusedTarget else { return hit.target }
        tabDragRefusedTarget = nil
        let rect = convert(hit.highlight, from: view)
        let region = convert(hit.region, from: view)
        tabDragHighlightOnScreen = window.map { $0.convertToScreen(convert(rect, to: nil)) }
        let style = context.style
        // Pane zones carry classic's 4 pt padding already (`classicPaneHighlight`); gaps and dock bands float
        // inside their region. The radius is classic's 8 pt unless the tunable follows the pane (-1).
        let paneZone = hit.target.isPaneZone
        let tunedRadius = CGFloat(DropOverlayTunables.cornerRadius.value)
        let radius = tunedRadius >= 0 ? tunedRadius
            : style.hasPaneChrome && paneZone ? PaneChromeGeometry.cornerRadius(for: rect, style: style) : style.panelCornerRadius
        let inset = paneZone ? 0 : DropOverlayTunables.floatingInset.resolve(Metrics.space2)
        if highlight.show(rect, region: region, zone: DropOverlayZone(hit.target), text: LayoutStrings.label(for: hit.target),
                          inset: inset, cornerRadius: radius, pointer: convert(locationInWindow, from: nil),
                          animated: canAnimate, companions: hit.companions.map { convert($0, from: view) }) { driver.start() }
        return hit.target
    }

    /// Marks a tab strip's insert slot (`screenRect`, the gap the strip
    /// opens for the dragged tab) with classic's caret: a 2 pt accent bar,
    /// 20 pt tall, on the gap's leading edge, where the tab will start; the
    /// drag ghost sits in the gap itself and would hide a centered caret
    /// (DESIGN.md (c)6, proof 2026-10-14). The same
    /// overlay as the pane zones, so it moves between them. Nothing is
    /// hit-tested; the strip owns that target, and the ghost still lands on
    /// the slot (`tabDragHighlightOnScreen`).
    public func showTabDragOutline(screenRect: CGRect) {
        guard let window else { return }
        let slot = convert(window.convertFromScreen(screenRect), from: nil)
        tabDragHighlightOnScreen = screenRect
        tabDropHit = nil
        tabDragShownTarget = nil
        tabDragRefusedTarget = nil
        let height = min(20, slot.height)
        let caret = CGRect(x: slot.minX - 2, y: slot.midY - height / 2, width: 2, height: height)
        if highlight.show(caret, region: caret, zone: .center, text: "", inset: 0, cornerRadius: 1,
                          pointer: CGPoint(x: caret.midX, y: caret.midY), animated: canAnimate, fills: false) { driver.start() }
    }

    /// Previews a pane drag's target `pane` (a swap) with the fill a tab dropped in that pane's
    /// center shows, so a pane drag and a tab drag share one preview (drop-zones DESIGN.md). Hides
    /// the preview when the pane is not on the active screen. Nothing is hit-tested here.
    public func showPaneDragTarget(_ pane: PaneID, locationInWindow: NSPoint) {
        guard let active = model.activeScreenID, let view = screenViews[active], let join = view.joinHighlight(pane) else {
            hideTabDragHighlight()
            return
        }
        tabDropHit = nil
        let rect = convert(join.highlight, from: view)
        tabDragHighlightOnScreen = window.map { $0.convertToScreen(convert(rect, to: nil)) }
        let tunedRadius = CGFloat(DropOverlayTunables.cornerRadius.value)
        let radius = tunedRadius >= 0 ? tunedRadius
            : context.style.hasPaneChrome ? PaneChromeGeometry.cornerRadius(for: rect, style: context.style) : context.style.panelCornerRadius
        if highlight.show(rect, region: convert(join.region, from: view), zone: .center, text: "", inset: 0, cornerRadius: radius,
                          pointer: convert(locationInWindow, from: nil), animated: canAnimate) { driver.start() }
    }

    /// Hides the drop highlight `updateTabDrag` showed, for a zone the App
    /// refuses: it draws nothing. The drag goes on, and the zone held near
    /// its line stays for the next hit test.
    public func hideTabDragHighlight() {
        tabDragRefusedTarget = tabDragShownTarget
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
        let target = updateTabDrag(tab, locationInWindow: locationInWindow, removing: tabDragRemoving, joinsFrom: tabDragJoinsFrom)
        hideHighlight()
        dragTab = nil
        tabDragRemoving = nil
        tabDragJoinsFrom = nil
        if let target { model.dropTab(tab, on: target) }
        return target
    }

    public func cancelTabDrag() {
        dragTab = nil
        tabDragRemoving = nil
        tabDragJoinsFrom = nil
        hideHighlight()
    }

    func hideHighlight() {
        tabDragHighlightOnScreen = nil
        tabDropHit = nil
        tabDragShownTarget = nil
        tabDragRefusedTarget = nil
        tabDragEdge = nil
        tabDragDwellDeadline = nil
        // Classic hides the overlay at once on a drop, a cancel or an exit.
        if highlight.hide(animated: false) { driver.start() }
    }

    // MARK: NSDraggingDestination

    private func tabID(from info: any NSDraggingInfo) -> TabID? {
        info.draggingPasteboard.string(forType: LayoutTabDrag.pasteboardType).map(TabID.init(rawValue:))
    }

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    /// A URL another app (or a web page) drags here, when the App takes link drops.
    private func linkURL(from info: any NSDraggingInfo) -> URL? {
        guard linkDropHandler != nil, tabID(from: info) == nil else { return nil }
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let url = linkURL(from: sender) {
            // A link from outside: the same zones as a tab; the App says which it can open.
            guard let target = updateTabDrag(TabID("link-drop"), locationInWindow: sender.draggingLocation) else {
                hideHighlight()
                return []
            }
            guard linkDropHandler?(url, target, false) == true else {
                hideTabDragHighlight()
                return []
            }
            return .copy
        }
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
        if let url = linkURL(from: sender) {
            let target = updateTabDrag(TabID("link-drop"), locationInWindow: sender.draggingLocation)
            cancelTabDrag()
            guard let target else { return false }
            return linkDropHandler?(url, target, true) == true
        }
        guard let tab = tabID(from: sender) else { return false }
        return endTabDrag(tab, locationInWindow: sender.draggingLocation) != nil
    }

    override public func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        cancelTabDrag()
    }
}

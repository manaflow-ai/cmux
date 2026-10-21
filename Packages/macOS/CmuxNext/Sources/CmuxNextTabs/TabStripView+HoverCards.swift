import AppKit
public import CmuxNextDesign

// The strip's side of the app's hover cards (HoverCardCoordinator); its targets
// (tabs and group chips) are hit-tested in `TabHoverCardController+Targets.swift`.
extension TabStripView {
    /// The coordinator this strip reports to (the App injects the app's one).
    public var hoverCards: HoverCardCoordinator {
        get { hoverCard.coordinator }
        set { hoverCard.coordinator = newValue }
    }

    /// Content moved under a possibly still pointer (layout, scroll,
    /// animation frame, the pane moved in its window): hover follows what
    /// is under the pointer now, and the coordinator re-hit-tests. Outside
    /// the visible strip (its visible rect can pass its bounds) is an exit (cx-3wu5).
    func geometryDidChange() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: hoverCards.currentPointer()), from: nil)
        let lit = buttonReveal.pointerInStrip || hoveredID != nil || groups.hoveredChip != nil
        let inside = bounds.intersection(visibleRect).contains(point) && !isHiddenOrHasHiddenAncestor
        if inside {
            if lit { updateHover(at: point, moved: false) }
        } else if lit || newTabButton.isHovered || closingModeWidth != nil { pointerLeft() }
        // A strip away from the pointer, with no card of its own, changes no card: no window
        // hit test for it (a tab switch or a strip animation elsewhere in the window).
        guard inside || lit || hoverCard.isVisible else { return }
        hoverCards.geometryChanged(in: window)
    }

    /// The pane holding this strip moved in its window (column scroll,
    /// split resize): see `geometryDidChange`.
    public func paneMovedInWindow() {
        geometryDidChange()
    }

    func clearHover() {
        setHovered(nil)
        setHoveredChip(nil)
        if let closeHoveredID { cells[closeHoveredID]?.isCloseHovered = false }
        closeHoveredID = nil
        setAudioHovered(nil)
    }
}

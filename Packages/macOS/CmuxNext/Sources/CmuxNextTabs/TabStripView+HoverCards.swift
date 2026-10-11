public import AppKit
public import CmuxNextDesign

// The strip's targets for the app's hover cards (TabHoverCardController,
// HoverCardCoordinator): tabs and group chips, hit-tested by position.
extension TabStripView {
    /// The coordinator this strip reports to (the App injects the app's one).
    public var hoverCards: HoverCardCoordinator {
        get { hoverCard.coordinator }
        set { hoverCard.coordinator = newValue }
    }

    /// The tab or chip under `point` (this view's coordinates) that may have
    /// a card now: none during any drag, an open group editor or a rename.
    func hoverCardTarget(at point: CGPoint) -> (id: TabID, width: CGFloat, anchor: CGRect)? {
        // Hidden strips (inactive screens share the frame) and clipped
        // parts never take a card.
        guard visibleRect.contains(point), !isHiddenOrHasHiddenAncestor, !isDraggingAnything, !groupEditor.isVisible,
              inlineRename.field == nil, let window else { return nil }
        if let group = chipGroup(at: point), let chip = groups.chips[group] {
            let anchor = window.convertToScreen(tabsClip.convert(chip.frame, to: nil))
            return (.groupChip(group), metrics.minInactiveTabWidth, anchor)
        }
        guard let id = tabID(at: point), let cell = cells[id] else { return nil }
        return (id, cell.frame.width, window.convertToScreen(tabsClip.convert(cell.frame, to: nil)))
    }

    /// `id`'s frame on screen now, nil when it has no visible frame.
    func hoverCardAnchor(for id: TabID) -> CGRect? {
        guard let window else { return nil }
        if let group = id.chipGroupID {
            guard let chip = groups.chips[group], chip.frame.width > 0.5 else { return nil }
            return window.convertToScreen(tabsClip.convert(chip.frame, to: nil))
        }
        guard let cell = cells[id], cell.frame.width > 0.5 else { return nil }
        return window.convertToScreen(tabsClip.convert(cell.frame, to: nil))
    }

    /// What `id`'s card shows, nil when the strip no longer has it.
    func hoverContent(for id: TabID) -> TabHoverCardContent? {
        if let group = id.chipGroupID {
            return groups.byID[group].map(groupHoverContent)
        }
        return model.tab(id).map(TabHoverCardContent.tab)
    }

    var isDraggingAnything: Bool {
        drag != nil || detachedID != nil || dropPlaceholderIndex != nil || groups.drag != nil || groups.detachedGroupID != nil
    }

    /// Content moved under a possibly still pointer (layout, scroll,
    /// animation frame, the pane moved in its window): hover follows what
    /// is under the pointer now, and the coordinator re-hit-tests. Outside
    /// the visible strip (its visible rect can pass its bounds) is an exit (cx-3wu5).
    func geometryDidChange() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: hoverCards.currentPointer()), from: nil)
        let lit = buttonReveal.pointerInStrip || hoveredID != nil || groups.hoveredChip != nil
        if bounds.intersection(visibleRect).contains(point), !isHiddenOrHasHiddenAncestor {
            if lit { updateHover(at: point, moved: false) }
        } else if lit || newTabButton.isHovered || closingModeWidth != nil { pointerLeft() }
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
    }
}

import AppKit
import CmuxNextDesign

// The strip's targets for the app's hover cards (TabHoverCardController,
// HoverCardCoordinator): tabs and group chips, hit-tested by position.
extension TabHoverCardController {
    /// The tab or chip under `point` (the strip's coordinates) that may have
    /// a card now: none during any drag, an open group editor or a rename.
    func target(at point: CGPoint) -> (id: TabID, width: CGFloat, anchor: CGRect)? {
        // Hidden strips (inactive screens share the frame) and clipped
        // parts never take a card.
        guard let strip, strip.visibleRect.contains(point), !strip.isHiddenOrHasHiddenAncestor, !isStripDragging(strip),
              !strip.groupEditor.isVisible, strip.inlineRename.field == nil, let window = strip.window else { return nil }
        if let group = strip.chipGroup(at: point), let chip = strip.groups.chips[group] {
            // `sidebar.hoverCards.groups.tabGroups` off: a chip opens no card.
            guard DesignSettings.shared.groupHoverCard.tabGroups else { return nil }
            let anchor = window.convertToScreen(strip.tabsClip.convert(Self.drawn(chip.frame, pill: chip.pillFrame), to: nil))
            return (.groupChip(group), strip.metrics.minInactiveTabWidth, anchor)
        }
        // A New Tab page's card would only repeat its title (Leo 2026-10-11).
        guard let id = strip.tabID(at: point), let cell = strip.cells[id], strip.model.tab(id)?.isNewTabPage != true else { return nil }
        // The speaker and the zoom indicator show their own tooltips (Mute tab, Exit Zoom), not the card over them.
        guard !strip.isInAudioButton(id, point), !strip.isInZoomButton(id, point) else { return nil }
        return (id, cell.frame.width, window.convertToScreen(strip.tabsClip.convert(Self.drawn(cell.frame, pill: cell.pillFrameInCell), to: nil)))
    }

    /// `id`'s frame on screen now, nil when it has no visible frame.
    func anchor(forTab id: TabID) -> CGRect? {
        guard let strip, let window = strip.window else { return nil }
        if let group = id.chipGroupID {
            guard let chip = strip.groups.chips[group], chip.frame.width > 0.5 else { return nil }
            return window.convertToScreen(strip.tabsClip.convert(Self.drawn(chip.frame, pill: chip.pillFrame), to: nil))
        }
        guard let cell = strip.cells[id], cell.frame.width > 0.5 else { return nil }
        return window.convertToScreen(strip.tabsClip.convert(Self.drawn(cell.frame, pill: cell.pillFrameInCell), to: nil))
    }

    /// The part of a tab's or chip's slot its pill draws: the card lines up with the edges the
    /// user sees (the slot also holds the gap to the next tab), across the slot's full height.
    static func drawn(_ slot: CGRect, pill: CGRect) -> CGRect {
        guard pill.width > 0.5, pill.width <= slot.width + 0.5 else { return slot }
        return CGRect(x: slot.minX + pill.minX, y: slot.minY, width: pill.width, height: slot.height)
    }

    /// What `id`'s card shows, nil when the strip no longer has it.
    func content(for id: TabID) -> TabHoverCardContent? {
        guard let strip else { return nil }
        if let group = id.chipGroupID {
            return strip.groups.byID[group].map(strip.groupHoverContent)
        }
        return strip.model.tab(id).map(TabHoverCardContent.tab)
    }

    private func isStripDragging(_ strip: TabStripView) -> Bool {
        strip.drag != nil || strip.detachedID != nil || strip.dropPlaceholderIndex != nil || strip.groups.drag != nil
            || strip.groups.detachedGroupID != nil
    }
}

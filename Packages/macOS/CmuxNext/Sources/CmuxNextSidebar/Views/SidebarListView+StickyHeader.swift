import AppKit
import CmuxNextDesign
import QuartzCore

/// The project header stuck at the top of the visible list: its row and where its view draws.
struct SidebarStuckHeader: Equatable {
    var key: SidebarRowKey
    var group: GroupID
    /// Where the header's view draws (list coordinates): at the visible top, or above it while the group's end pushes it.
    var frame: NSRect
    /// The header's own y in the layout, where it draws at rest.
    var restY: CGFloat
}

// Sticky project headers (Leo, 2026-11-10: "Obviously we want infinite scroll ... you also don't want to make a, like a
// scrollable area within a scrollable area"). The sidebar stays the one scroll area: while it scrolls through an open
// top-level group, the group's own header view draws at the top of the visible rows until the group's last row passes
// (`SidebarLayout.stuckHeader`), on the gallery's `veil` (`SidebarStuckVeilView`). It is the same view, so hover, its
// card, clicks, its menu, the keyboard and VoiceOver reach the same header. Each scroll frame costs one lookup by y and
// one frame set, whatever the group's size. Nested groups' headers do not stick: their top-level header does, so two
// pinned headers never stack over the rows.
extension SidebarListViewComponents {
    /// The y the visible rows start at: the clip's top under the part the traffic lights cover (`stickyTopInset`). Nil
    /// outside a scroll view (a space page never scrolls) or before the clip has a height.
    var stickyTop: CGFloat? {
        guard let clip = enclosingScrollView?.contentView, clip.bounds.height > 0 else { return nil }
        return clip.bounds.minY + stickyTopInset
    }

    /// The top-level group `id` sits in (itself at the top level).
    func topLevelGroup(_ id: GroupID) -> GroupID {
        var current = id
        // A parent cycle in a broken document stops at the depth any drawn tree has.
        for _ in 0..<64 {
            guard let parent = groups[current]?.parent, groups[parent] != nil else { break }
            current = parent
        }
        return current
    }

    /// The header that sticks in `layout` at the current scroll, or nil. A drag keeps it: the rows' frames it springs
    /// are the drawn ones (`drawnFrame`), so a member dragged in a long group leaves the header where it is.
    func findStuckHeader(in layout: SidebarLayout) -> SidebarStuckHeader? {
        guard sticksHeaders, let top = stickyTop,
              let hit = layout.stuckHeader(at: top, topLevel: topLevelGroup) else { return nil }
        let row = layout.rows[hit.position]
        guard case let .group(group) = row.key else { return nil }
        var frame = frame(for: row)
        frame.origin.y = hit.y
        return SidebarStuckHeader(key: row.key, group: group, frame: frame, restY: row.y)
    }

    /// Where `row`'s view draws: the stuck header's frame for the stuck header, else the row's own (`frame(for:)`, which
    /// hit testing, group lines and drags keep reading).
    func drawnFrame(for row: SidebarRow) -> NSRect {
        if let stuckHeader, stuckHeader.key == row.key { return stuckHeader.frame }
        return frame(for: row)
    }

    /// The band the stuck header covers, across the list's width: a point in it is on the header, not on the rows under it.
    var stuckBand: NSRect? {
        stuckHeader.map { NSRect(x: 0, y: $0.frame.minY, width: bounds.width, height: $0.frame.height) }
    }

    /// The stuck header's row when `point` (list coordinates) is on it.
    func stuckHit(at point: CGPoint) -> SidebarRow? {
        guard let stuckHeader, let band = stuckBand, band.contains(point), rowViews[stuckHeader.key] != nil else { return nil }
        return displayed.row(for: stuckHeader.key)
    }

    /// A scroll frame (`realizeVisibleRows`): the header that sticks now draws at its place, made when the scroll jumped
    /// into a group whose header had no view; the one that let go goes back to its own place. One lookup and at most
    /// two frame sets.
    func followStuckHeader() {
        SidebarPerfCounters.add(.stuckHeaderUpdates)
        let previous = stuckHeader
        stuckHeader = findStuckHeader(in: displayed)
        if let stuck = stuckHeader, let row = displayed.row(for: stuck.key) {
            if let view = rowViews[stuck.key] {
                if view.frame != stuck.frame { Motion.withoutAnimation { view.frame = stuck.frame } }
            } else {
                let view = dequeue(stuck.key, rebinding: true)
                view.targetSize = stuck.frame.size
                configure(view, row: row, animated: false)
                if view.superview !== self { addSubview(view, positioned: .above, relativeTo: decorations) }
                RowMotion.place(view, at: stuck.frame, opening: nil, hidden: suppressed.contains(stuck.key), in: self)
                rowViews[stuck.key] = view
            }
        }
        if let previous, previous.key != stuckHeader?.key, let view = rowViews[previous.key], let row = displayed.row(for: previous.key) {
            let rest = frame(for: row)
            if view.frame != rest { Motion.withoutAnimation { view.frame = rest } }
        }
        showStuckHeader(previous: previous)
    }

    /// The end of a pass that laid rows out with `stuckHeader` set for its layout (an apply, a fold, a drag's look): the
    /// stuck header gets a view if the pass made none, the one that let go stays on the spring home the pass gave it.
    func endStuckPass(from previous: SidebarStuckHeader?) {
        stuckHeader = previous
        followStuckHeader()
    }

    /// Draws the stuck header over the rows on its veil, or the veil gone when none is stuck. Frames are the caller's
    /// (a scroll sets them, an apply moves them on its spring).
    func showStuckHeader(previous: SidebarStuckHeader?) {
        if let previous, previous.key != stuckHeader?.key { rowViews[previous.key]?.layer?.zPosition = 0 }
        let wasShown = !stuckVeil.isHidden
        guard let stuck = stuckHeader, let view = rowViews[stuck.key] else {
            if wasShown {
                stuckVeil.isHidden = true
                onStuckHeaderChange?(false)
            }
            return
        }
        // Over the rows it covers and its veil, whatever their order among the list's subviews.
        if view.layer?.zPosition != 2 { view.layer?.zPosition = 2 }
        if stuckVeil.layer?.zPosition != 1 { stuckVeil.layer?.zPosition = 1 }
        Motion.withoutAnimation { stuckVeil.place(under: stuck.frame, width: bounds.width) }
        if !wasShown {
            stuckVeil.isHidden = false
            onStuckHeaderChange?(true)
        }
    }

    /// A collapse of the stuck group (a click on the stuck header, the keyboard, the menu): its header stays where it
    /// draws. The rows and the offset move together by the header's distance from its own place, so nothing on screen
    /// moves and the header is at its own place at the top; the fold then closes the members' slot under it as any fold
    /// does (`applyFold`). Without this the fold would close the slot far above, out of view, and the list would jump.
    func keepStuckHeaderForFold(of id: GroupID, collapsing: Bool) {
        guard collapsing, let stuck = stuckHeader, stuck.group == id, let clip = enclosingScrollView?.contentView else { return }
        let delta = max(-clip.bounds.minY, stuck.restY - stuck.frame.minY)
        stuckHeader = nil
        showStuckHeader(previous: stuck)
        guard abs(delta) > 0.25 else { return }
        RowMotion.shift(self, by: delta)
        Motion.withoutAnimation {
            decorations.shift(by: delta)
            groupLineViews.shift(by: delta)
            chatHistory.shift(by: delta)
            // The fold realizes the rows from its layout, not this scroll.
            isShiftingViewport = true
            clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + delta))
            enclosingScrollView?.reflectScrolledClipView(clip)
            isShiftingViewport = false
        }
    }

    /// `item` (a reveal's extent) with room above it for the header that sticks over its group, so a row the keyboard
    /// or a selection reveals never lands under the stuck header. Unchanged when its group's header is part of it or the
    /// row is in no open group.
    func revealClearOfStuckHeader(_ item: ListViewport<SidebarRowKey>.Item, in layout: SidebarLayout) -> ListViewport<SidebarRowKey>.Item {
        guard sticksHeaders, enclosingScrollView != nil, let index = layout.lastIndex(startingAtOrBefore: item.start),
              let member = layout.rows[index].group,
              let header = layout.row(for: .group(topLevelGroup(member))), !header.isCollapsed, header.y < item.start else { return item }
        return .init(id: item.id, start: item.start - header.height, length: item.length + header.height)
    }
}

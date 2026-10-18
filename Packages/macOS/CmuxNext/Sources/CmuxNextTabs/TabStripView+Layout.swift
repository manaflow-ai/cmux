import AppKit
public import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore
// Layout, frame application (edge fades: `TabEdgeFade`), and the FrameScheduler animation client.
extension TabStripView {
    // MARK: - Layout

    func layoutItems() -> [TabLayoutItem] {
        var tabs = displayed
        if let drag, let from = tabs.firstIndex(where: { $0.id == drag.id }) {
            var item = tabs.remove(at: from)
            item.groupID = drag.targetGroup
            tabs.insert(item, at: min(max(drag.currentIndex, 0), tabs.count))
        }
        if let groupDrag = groups.drag {
            let members = tabs.filter { groupDrag.memberIDs.contains($0.id) }
            tabs.removeAll { groupDrag.memberIDs.contains($0.id) }
            tabs.insert(contentsOf: members, at: min(max(groupDrag.currentTabIndex, 0), tabs.count))
        }
        var items = TabGroupOrdering.layoutItems(tabs, groups: groups.byID, selectedID: model.selectedID, chipWidths: groups.chipWidths())
        if let index = dropPlaceholderIndex {
            let pinnedCount = tabs.count(where: \.isPinned)
            let placeholder = TabLayoutItem(id: Self.placeholderID, groupID: dropPlaceholderGroup, fixedWidth: groups.phantomWidth)
            items.insertPlaceholder(placeholder, atTabIndex: max(index, pinnedCount))
        }
        return items
    }

    /// `growsAdded` (default false): the `added` tabs open the Chrome way (`ui.animations.newTab` on,
    /// outside a gesture); otherwise they are there at once at full width (nx-cmdt-fix). `token` is the
    /// tween the tabs move on (open when tabs grow in, else this, else `tabMove`): Chrome moves every
    /// tab from where it is to its slot on one 200 ms ease-out, restarted only by a new target.
    /// `keepsSelectedInView`: the strip scrolls to the selected tab.
    func relayout(animated: Bool, added: Set<TabID> = [], growsAdded: Bool = false, token: MotionTween? = nil, keepsSelectedInView: Bool = false) {
        let grows = growsAdded
        result = TabLayoutEngine.layout(
            items: layoutItems(),
            availableWidth: viewportWidth,
            style: model.style,
            metrics: metrics,
            closingModeWidth: closingModeWidth
        )
        // A new tab (Cmd-T, +, a script's tab) with `ui.animations.newTab` off is there at once, at its
        // slot and full width, and the tabs make room for it in the same frame. A drag or a torn-out
        // tab's drop keeps every move in flight as it was.
        let insertsAtOnce = !added.isEmpty && drag == nil && pendingDrop == nil && !grows
        let move = animated && !insertsAtOnce ? stripMove(grows ? .tabOpen : token ?? .tabMove) : nil
        // The previous tab's right edge as it is on screen now (Chrome StartInsertTabAnimation reads the
        // previous tab's current bounds): a new tab opens there and slides with it to its slot, so the
        // two move in lockstep on the same tween and never overlap (the proof's open overlap and the
        // cx-4t1tc hit test: a slot-based start sat under the still-shrinking previous tab).
        var previousMaxX: CGFloat?
        var starts: [TabID: TabPlace] = [:]
        for slot in result.slots where slot.id != Self.placeholderID {
            defer { if grows { previousMaxX = starts[slot.id]?.maxX ?? shownMaxX(slot.id) ?? slot.maxX } }
            guard var place = placed[slot.id] else { continue }
            if added.contains(slot.id), move != nil {
                if let pendingDrop, pendingDrop.id == slot.id {
                    starts[slot.id] = TabPlace(x: pendingDrop.x, width: pendingDrop.width)
                } else if grows {
                    // Chrome (StartInsertTabAnimation): from the previous tab's current right edge minus
                    // the open width, that wide, no fade; the first tab starts at its slot. Chrome's 18 is
                    // its tab overlap (a tab 18 wide shows nothing); ours do not overlap, so the token
                    // is 0: the tab opens from nothing at the previous right edge (hq-4e 2026-10-15).
                    let open = metrics.chrome.openStartWidth
                    // A new first tab (index 0) opens at its slot from that width while the old first tab
                    // slides right; only a strip's very first tab is there at once (Chrome).
                    let alone = result.slots.count(where: { $0.id != Self.placeholderID }) == 1
                    starts[slot.id] = previousMaxX.map { TabPlace(x: $0 - open, width: open) }
                        ?? TabPlace(x: slot.x, width: alone ? slot.width : open)
                }
            }
            if pendingDrop?.id == slot.id, added.contains(slot.id) { pendingDrop = nil }
            // The dragged tab sits exactly under the pointer (`updateDrag`); a dragged group's members follow the block.
            if drag?.id != slot.id { place.x = groupDragX(for: slot) ?? slot.x }
            place.width = slot.width
            // Members of a collapsed group shrink into the chip and fade.
            place.alpha = slot.isCollapsed ? 0 : 1
            // Any other new tab or chip is at its place from its first frame.
            if added.contains(slot.id), move != nil, starts[slot.id] == nil { starts[slot.id] = place }
            placed[slot.id] = place
        }
        pinClosingTabs()
        scrollOffset = TabScrollMath.clamp(scrollOffset, contentWidth: result.contentWidth, viewportWidth: viewportWidth)
        if keepsSelectedInView, drag == nil, let slot = model.selectedID.flatMap({ result.slot($0) }) {
            scrollOffset = TabScrollMath.offset(revealing: slot, current: scrollOffset, contentWidth: result.contentWidth, viewportWidth: viewportWidth,
                                                margin: metrics.scrollFadeWidth, fixedLeading: scrollMapping.band)
        }
        // No motion (not animated, a tab there at once, a window with no screen): a closing tab's room is
        // already given away, so it goes now too, one consistent frame.
        if move == nil { for id in dying { removeTab(id) } }
        TabSeparatorVisibility.apply(to: self)
        // An opening tab first shows where it opens from; the move takes it to its slot.
        if !starts.isEmpty { place(starts) }
        applyFrames(move: move)
        overflowHints.update()
    }

    /// A closing tab's left edge stays on the previous tab's right edge minus the close width (0: our
    /// tabs do not overlap) while it shrinks to that width (Chrome StartRemoveTabAnimation), following
    /// that tab as it resizes: both move on one tween from one frame. The previous tab is the one left
    /// of it when it closed (by order, not by x: a tab opened meanwhile must not move it a slot); the
    /// first tab keeps its x.
    func pinClosingTabs() {
        let closeWidth = metrics.chrome.closeEndWidth
        for id in dying where id.chipGroupID == nil {
            guard var place = placed[id] else { continue }
            let previousMaxX: CGFloat?
            if let anchor = closingAnchors[id] {
                // The left neighbour's slot, or its own closing geometry when it is closing too.
                previousMaxX = anchor.flatMap { a in result.slot(a)?.maxX ?? placed[a]?.maxX }
            } else {
                previousMaxX = result.slots.last { $0.id != Self.placeholderID && $0.x < place.x - 0.5 }?.maxX
            }
            place.x = previousMaxX.map { $0 - closeWidth } ?? place.x
            placed[id] = place
        }
    }

    /// The motion of a strip change on `token`, or nil when it applies at once (the token does not
    /// animate, or the window has no screen, where Core Animation would never end it).
    func stripMove(_ token: MotionTween) -> TabStripMove? {
        guard let motion = MotionMove.tween(token), Motion.canAnimate(in: self) else { return nil }
        moveGeneration += 1
        return TabStripMove(generation: moveGeneration, motion: motion, closing: token == .tabClose ? nil : MotionMove.tween(.tabClose))
    }

    /// Every move of `generation` ended: a closing tab or chip it carried goes, and the masks and
    /// clips that only that motion needed come off.
    func moveEnded(_ generation: Int) {
        for id in dying where lastMove[id] == generation { removeTab(id) }
        for (id, move) in occlusionMoves where move == generation {
            occlusionMoves[id] = nil
            cells[id]?.occlude(by: nil)
        }
        for (id, move) in clipMoves where move == generation {
            clipMoves[id] = nil
            cells[id]?.clipsMotion = false
        }
    }

    func reveal(_ id: TabID, animated: Bool) {
        guard let slot = result.slot(id) else { return }
        let target = TabScrollMath.offset(
            revealing: slot,
            current: scrollOffset,
            contentWidth: result.contentWidth,
            viewportWidth: viewportWidth,
            margin: metrics.scrollFadeWidth,
            fixedLeading: scrollMapping.band
        )
        // Already in view (a switch between shown tabs): the strip does not move.
        guard target != scrollOffset else { return }
        scrollOffset = target
        var move: TabStripMove?
        if animated, !reduceMotion, Motion.canAnimate(in: self), let motion = MotionMove.spring(.scroll) {
            moveGeneration += 1
            move = TabStripMove(generation: moveGeneration, motion: motion, closing: nil)
        }
        applyFrames(move: move)
    }

    /// Where `id`'s cell shows now, its right edge in content coordinates (the presentation layer
    /// includes every move in flight); nil when it has no cell.
    func shownMaxX(_ id: TabID) -> CGFloat? {
        guard let layer = cells[id]?.layer ?? id.chipGroupID.flatMap({ groups.chips[$0]?.layer }) else { return nil }
        let frame = (layer.presentation() ?? layer).frame
        return scrollMapping.contentX(frame.maxX, isPinned: cells[id]?.item.isPinned ?? false)
    }

    /// Where `id`'s cell shows now, its left edge in content coordinates.
    func shownX(_ id: TabID) -> CGFloat? {
        guard let cell = cells[id] else { return nil }
        return scrollMapping.contentX((cell.layer.presentation() ?? cell.layer).frame.minX, isPinned: cell.item.isPinned)
    }

    /// The strip's scroll mapping now: pinned tabs fixed, unpinned tabs at the scroll's current value.
    var scrollMapping: TabScrollMapping { scrollMapping(offset: scrollOffset) }

    /// The scroll mapping of the current layout at `offset` (the target, for settled geometry).
    func scrollMapping(offset: CGFloat) -> TabScrollMapping {
        TabScrollMapping(result: result, viewportWidth: viewportWidth, minimumScrollable: metrics.minActiveTabWidth, offset: offset)
    }

    /// The layer a tab's cell draws in: `tabsClip`'s for a pinned tab, else the clipped scrolling layer.
    func tabsLayer(isPinned: Bool) -> CALayer? {
        isPinned ? tabsClip.layer : scrollingLayer
    }

    /// The cell's frame in its layer for `place` at the current scroll.
    func cellFrame(_ place: TabPlace, isPinned: Bool) -> CGRect {
        let mapping = scrollMapping
        let scale = window?.backingScaleFactor ?? 2
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = pixel(mapping.viewX(place.x, isPinned: isPinned))
        let maxX = pixel(mapping.viewX(place.x + max(0, place.width), isPinned: isPinned))
        return CGRect(x: minX, y: tabTop, width: maxX - minX, height: min(metrics.tabHeight, bounds.height))
    }

    /// Shows the cells of `places` there at once (where an opening tab opens from); `placed` is unchanged.
    func place(_ places: [TabID: TabPlace]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, place) in places {
            guard let cell = cells[id] else { continue }
            TabStripMove.cancel(cell.layer)
            cell.frame = cellFrame(place, isPinned: cell.item.isPinned)
        }
        CATransaction.commit()
    }

    /// Writes every cell, chip, band and the + at its place now. With `move`, each layer the change moved
    /// animates there from where it was (render server, no per-frame work here); without, it is there at
    /// once while any move in flight keeps running on top (a scroll, a resize). The dragged tab and a
    /// dragged group never animate: they sit exactly under the pointer.
    func applyFrames(move: TabStripMove? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let move {
            let generation = move.generation
            CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.moveEnded(generation) } } // main-proof: CATransaction.h: the completion block is called on the main thread
        }
        defer { CATransaction.commit() }
        let tabHeight = min(metrics.tabHeight, bounds.height)
        let tabY = tabTop
        let mapping = scrollMapping
        let offset = mapping.offset(isPinned: false)
        let scale = window?.backingScaleFactor ?? 2
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        // The scrolling layer starts after the pinned band, with tabsClip's coordinates inside.
        let clip = tabsClip.bounds
        scrollingLayer.frame = CGRect(x: mapping.band, y: clip.minY, width: max(0, clip.width - mapping.band), height: clip.height)
        scrollingLayer.bounds.origin = CGPoint(x: mapping.band, y: clip.minY)
        let selected = model.selectedID.flatMap { dying.contains($0) ? nil : $0 }
        // What the selected pill crosses on the way is sampled from where everything shows now.
        let occlusionStart = move.flatMap { $0.motion.isTween && selected != nil ? TabOcclusion.start(cells: cells) : nil }
        var trailing: CGFloat = 0
        for (id, cell) in cells {
            guard let place = placed[id] else { continue }
            let isPinned = cell.item.isPinned
            // A tab pinned or unpinned since it was made moves to its region's layer.
            if let parent = tabsLayer(isPinned: isPinned), cell.layer.superlayer !== parent { parent.addSublayer(cell.layer) }
            let frame = cellFrame(place, isPinned: isPinned)
            let opacity = Float(min(max(place.alpha, 0), 1))
            let direct = drag?.id == id || groups.isDragged(id)
            if direct { TabStripMove.cancel(cell.layer) }
            if let move, !direct, frame != cell.frame || opacity != cell.layer.opacity {
                let before = TabStripMove.snapshot(cell.layer)
                // A widening tab clips its content (laid out at the new width) to its bounds on the way.
                if frame.width > cell.frame.width + 0.5 {
                    cell.clipsMotion = true
                    clipMoves[id] = move.generation
                }
                cell.frame = frame
                cell.layer.opacity = opacity
                if move.animate(from: before, closing: dying.contains(id)), dying.contains(id) { lastMove[id] = move.generation }
            } else {
                cell.frame = frame
                cell.layer.opacity = opacity
            }
            // A closing tab nothing moved goes when this change ends.
            if let move, dying.contains(id), lastMove[id] == nil { lastMove[id] = move.generation }
            cell.accessibility.setAccessibilityFrameInParentSpace(tabsClip.convert(cell.frame, to: self))
            trailing = max(trailing, place.maxX)
        }
        var occluding: Set<TabID> = []
        if let move, let occlusionStart {
            occluding = TabOcclusion.animate(cells: cells, selected: selected, band: mapping.band, from: occlusionStart, move: move)
            for id in occluding { occlusionMoves[id] = move.generation }
        }
        TabOcclusion.apply(cells: cells, selected: selected, in: tabsClip.layer, band: mapping.band,
                           skipping: { occluding.contains($0) || self.occlusionMoves[$0] != nil })
        for group in groups.chips.keys {
            guard let place = placed[.groupChip(group)] else { continue }
            trailing = max(trailing, place.maxX)
        }
        applyGroupFrames(offset: offset, tabY: tabY, tabHeight: tabHeight, pixel: pixel, move: move)
        let buttonWidth = metrics.newTabButtonWidth
        let buttonX = tabsClip.frame.minX + min(trailing - offset, viewportWidth)
        // Square, centered on the tabs: it keeps its size when the tabs are shorter.
        let buttonFrame = CGRect(x: pixel(buttonX), y: pixel(tabY + (tabHeight - buttonWidth) / 2), width: buttonWidth, height: buttonWidth)
        let buttonFrom = newTabButton.frame.origin
        newTabButton.frame = buttonFrame
        if let move, let layer = newTabButton.layer, buttonFrom != buttonFrame.origin {
            // A view's layer is in its superview's (flipped or not) coordinates: its position moved as its frame did.
            let delta = CGPoint(x: buttonFrom.x - buttonFrame.minX, y: buttonFrom.y - buttonFrame.minY)
            move.add(move.motion.additive("position", from: NSValue(point: delta), to: NSValue(point: .zero)), to: layer, as: "button")
        }
        edgeFade.update()
        // Tabs moved (scroll, reflow, close): what is under a still pointer may differ. Hit testing reads
        // the targets, the frames written above.
        geometryDidChange()
        // A drag, a group drag or a torn-out tab over the strip autoscrolls at an edge.
        if drag != nil || groups.drag != nil || phantomPoint != nil { startAnimating() }
    }

    // MARK: - Drag autoscroll

    /// Runs drag autoscroll on the window's one `MotionClock`. Nothing else in the strip steps per frame.
    func startAnimating() {
        guard window != nil else { return }
        let clock = MotionClock.forView(self)
        if let motionClock, motionClock !== clock { motionClock.stop(self) }
        motionClock = clock
        clock.run(self, trace: "tabs.autoscroll")
    }
}

extension TabStripView: MotionAnimating {
    /// One autoscroll frame; false when no drag sits in an edge fade.
    public func motionStep(_ dt: Double) -> Bool { autoscrollDuringDrag(CGFloat(dt)) }
}

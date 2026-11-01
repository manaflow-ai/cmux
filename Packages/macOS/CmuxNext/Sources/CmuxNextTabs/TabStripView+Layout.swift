import AppKit
import CmuxNextCompat
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
            closingModeWidth: closingModeWidth,
            fullWidthTab: model.showsSelectedFullWidth ? model.selectedID : nil
        )
        // A new tab (Cmd-T, +, a script's tab) with `ui.animations.newTab` off is there at once, at its
        // slot and full width, and the tabs make room for it in the same frame. A drag or a torn-out
        // tab's drop keeps every move in flight as it was.
        let insertsAtOnce = !added.isEmpty && drag == nil && pendingDrop == nil && !grows
        // An opening tab's start is placed with the scroll as it was, so the scroll's change moves it as it moves its neighbours.
        let mappingBefore = scrollMapping
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
        if !starts.isEmpty { place(starts, mapping: mappingBefore) }
        applyFrames(move: move, scrollFrom: mappingBefore)
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
        guard let motion = MotionMove.tween(token, in: Motion.tabs), Motion.canAnimate(in: self) else { return nil }
        moveGeneration += 1
        return TabStripMove(generation: moveGeneration, motion: motion, closing: token == .tabClose ? nil : MotionMove.tween(.tabClose, in: Motion.tabs))
    }

    /// Every move of `generation` ended: a closing tab or chip it carried goes, and the masks and
    /// clips that only that motion needed come off.
    func moveEnded(_ generation: Int) {
        movesInFlight.remove(generation)
        let now = CACurrentMediaTime()
        // The move that ends last carries it; a little slack for the completion's own frame.
        for id in dying where (goesAt[id] ?? .infinity) <= now + 0.02 { removeTab(id) }
        // A tab's parts at rest again: placed, the parts they no longer need removed.
        for cell in cells.values where (cell.innerPath?.end ?? .infinity) <= now + 0.02 { cell.layoutLayers() }
        // Masks whose path ended come off (or stay, exact, for what still moves).
        if occlusionEnds.values.contains(where: { $0 <= now + 0.02 }) { updateOcclusion(settle: 0.02) }
    }

    /// Masks the tabs the selected pill covers now and along every move in flight (`TabOcclusion`).
    /// `settle`: a path that ends within it counts as ended.
    func updateOcclusion(settle: CFTimeInterval = 0.001) {
        rowPasses.occlusion &+= 1
        let selected = model.selectedID.flatMap { dying.contains($0) ? nil : $0 }
        occlusionEnds = TabOcclusion.update(cells: cells, selected: selected, band: scrollMapping.band, settle: settle)
    }

    /// `result` by tab, built once per layout.
    var slotIndex: TabSlotIndex {
        if let slotIndexCache { return slotIndexCache }
        let index = TabSlotIndex(result)
        slotIndexCache = index
        return index
    }

    func reveal(_ id: TabID, animated: Bool) {
        guard let slot = slotIndex.slots[id] else { return }
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
        let from = scrollMapping
        scrollOffset = target
        var move: TabStripMove?
        if animated, !reduceMotion, Motion.canAnimate(in: self), let motion = MotionMove.spring(.scroll, in: Motion.tabs) {
            moveGeneration += 1
            move = TabStripMove(generation: moveGeneration, motion: motion, closing: nil, isScroll: true)
        }
        applyFrames(move: move, scrollFrom: from)
    }

    /// A wheel or a drag's autoscroll takes the scroll over: the scroll part of every move still in
    /// flight (a reveal's spring, a relayout that keeps the selected tab in view) ends where it shows
    /// now (the scroll offset becomes that), so nothing drifts against the gesture; the rest of a
    /// relayout (tabs making room, a close) keeps moving.
    func settleScroll() {
        guard scrollProbe.animationKeys()?.isEmpty == false else { return }
        // What the scroll parts add now (a view x is the content x minus the offset): the probe takes only them.
        let shown = MotionPath(scrollProbe, "position").value(at: CACurrentMediaTime()).x
        scrollOffset = TabScrollMath.clamp(scrollOffset - (shown - scrollProbe.position.x), contentWidth: result.contentWidth,
                                           viewportWidth: viewportWidth)
        var layers = [scrollProbe] + cells.values.map(\.layer) + groups.chips.values.map(\.layer)
        layers += groups.bands.values.flatMap { [$0.washLayer, $0.lineLayer] }
        layers += [newTabButton.layer, newTabMenuButton.layer].compactMap { $0 }
        TabStripMove.cancelScroll(on: layers)
    }

    /// A closing tab or chip in `move` (`moved`: it animated in it) goes when its last move ends; one
    /// the change did not move goes when this change ends.
    func noteClosing(_ id: TabID, moved: Bool, move: TabStripMove) {
        guard dying.contains(id) else { return }
        // A reveal's spring only scrolls it (it may be cut short by a wheel): the close decides when it goes.
        let end = CACurrentMediaTime() + (moved && !move.isScroll ? move.duration(closing: id.chipGroupID == nil) : 0)
        goesAt[id] = max(goesAt[id] ?? 0, end)
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
    func cellFrame(_ place: TabPlace, isPinned: Bool) -> CGRect { cellFrame(place, isPinned: isPinned, mapping: scrollMapping) }

    /// The cell's frame in its layer for `place` at `mapping`'s scroll.
    func cellFrame(_ place: TabPlace, isPinned: Bool, mapping: TabScrollMapping) -> CGRect {
        let scale = window?.backingScaleFactor ?? 2
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = pixel(mapping.viewX(place.x, isPinned: isPinned))
        let maxX = pixel(mapping.viewX(place.x + max(0, place.width), isPinned: isPinned))
        return CGRect(x: minX, y: tabTop, width: maxX - minX, height: min(metrics.tabHeight, bounds.height))
    }

    /// Shows the cells and chips of `places` there at once, at `mapping`'s scroll (where a new tab
    /// opens from, or a new chip first shows); `placed` is unchanged.
    func place(_ places: [TabID: TabPlace], mapping: TabScrollMapping) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, place) in places {
            if let cell = cells[id] {
                // A tab dropped back may still carry its lift's moves.
                TabStripMove.cancel(cell.layer)
                cell.frame = cellFrame(place, isPinned: cell.item.isPinned, mapping: mapping)
                // Its parts end the path they followed (a resize already laid them out at rest).
                if cell.innerPath != nil { cell.layoutLayers() }
            } else if let group = id.chipGroupID, let chip = groups.chips[group] {
                chip.frame = cellFrame(place, isPinned: false, mapping: mapping)
            }
        }
        CATransaction.commit()
    }

    /// Writes every cell, chip, band and the + at its place now. With `move`, each layer the change moved
    /// animates there from where it was (render server, no per-frame work here); without, it is there at
    /// once while any move in flight keeps running on top (a scroll, a resize). The dragged tab and a
    /// dragged group never animate: they sit exactly under the pointer.
    /// `scrollFrom`: the mapping the layers showed before (its offset); with `move`, the scroll's share
    /// of each move runs under its own key (`TabStripMove.addScroll`), so a wheel ends it alone.
    func applyFrames(move: TabStripMove? = nil, scrollFrom: TabScrollMapping? = nil) {
        rowPasses.frames &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let move {
            let generation = move.generation
            movesInFlight.insert(generation)
            CATransaction.setMainCompletion { [weak self] in self?.moveEnded(generation) }
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
        // The view x the scroll alone moved a layer of each region by (shown before minus now).
        func scrollPart(isPinned: Bool) -> CGFloat {
            guard let scrollFrom else { return 0 }
            return mapping.offset(isPinned: isPinned) - scrollFrom.offset(isPinned: isPinned)
        }
        if let move, abs(scrollPart(isPinned: false)) > 0.01 {
            if scrollProbe.superlayer == nil { tabsClip.layer?.addSublayer(scrollProbe) }
            move.addScroll(scrollPart(isPinned: false), to: scrollProbe)
        }
        var trailing: CGFloat = 0
        for (id, cell) in cells {
            guard let place = placed[id] else { continue }
            let isPinned = cell.item.isPinned
            // A tab pinned or unpinned since it was made moves to its region's layer.
            if let parent = tabsLayer(isPinned: isPinned), cell.layer.superlayer !== parent { parent.addSublayer(cell.layer) }
            let frame = cellFrame(place, isPinned: isPinned)
            let opacity = Float(min(max(place.alpha, 0), 1))
            var moved = false
            // A tab the scroll alone moves keeps its place on screen: its scroll part and the rest cancel.
            if let move, frame != cell.frame || opacity != cell.layer.opacity || abs(scrollPart(isPinned: isPinned)) > 0.01 {
                // The root moves; its parts follow its width path (`TabCell.retimeInner`), its mask the pill's (`TabOcclusion`).
                let before = TabStripMove.snapshot(cell.layer, depth: 0, masks: false)
                let resized = frame.size != cell.frame.size
                cell.setFrame(frame, laysOut: false)
                cell.layer.opacity = opacity
                moved = move.animate(from: before, closing: dying.contains(id), scroll: scrollPart(isPinned: isPinned))
                if resized { cell.layoutLayers() }
            } else {
                cell.frame = frame
                cell.layer.opacity = opacity
            }
            // The dragged tab and a dragged group's members sit exactly under the pointer (their width still moves).
            if drag?.id == id || groups.isDragged(id) { TabStripMove.cancelPosition(cell.layer) }
            if let move { noteClosing(id, moved: moved, move: move) }
            cell.accessibility.setAccessibilityFrameInParentSpace(tabsClip.convert(cell.frame, to: self))
            trailing = max(trailing, place.maxX)
        }
        updateOcclusion()
        for group in groups.chips.keys {
            guard let place = placed[.groupChip(group)] else { continue }
            trailing = max(trailing, place.maxX)
        }
        applyGroupFrames(offset: offset, tabY: tabY, tabHeight: tabHeight, pixel: pixel, move: move, scroll: scrollPart(isPinned: false))
        let buttonWidth = metrics.newTabButtonWidth
        let buttonX = tabsClip.frame.minX + min(trailing - offset, viewportWidth)
        // Square, centered on the tabs: it keeps its size when the tabs are shorter.
        let buttonFrame = CGRect(x: pixel(buttonX), y: pixel(tabY + (tabHeight - buttonWidth) / 2), width: buttonWidth, height: buttonWidth)
        let buttonFrom = newTabButton.frame.origin
        newTabButton.frame = buttonFrame
        newTabMenuButton.frame = CGRect(x: buttonFrame.maxX, y: buttonFrame.minY,
                                       width: newTabControlsWidth - buttonWidth, height: buttonFrame.height)
        // The scroll moves it only where it follows the last tab both before and now (not held at the strip's end).
        let buttonEnd = pixel(tabsClip.frame.minX + viewportWidth) - 0.5
        let scroll = buttonFrame.minX < buttonEnd && buttonFrom.x < buttonEnd ? scrollPart(isPinned: false) : 0
        if let move, buttonFrom != buttonFrame.origin || abs(scroll) > 0.01 {
            // Both controls follow the same move and scroll, staying adjacent throughout the transition.
            let delta = CGPoint(x: buttonFrom.x - buttonFrame.minX - scroll, y: buttonFrom.y - buttonFrame.minY)
            for layer in [newTabButton.layer, newTabMenuButton.layer].compactMap({ $0 }) {
                if abs(delta.x) > 0.01 || abs(delta.y) > 0.01 {
                    move.add(move.motion.additive("position", from: NSValue(point: delta), to: NSValue(point: .zero)), to: layer, as: "button")
                }
                move.addScroll(scroll, to: layer)
            }
        }
        edgeFade.update()
        // Tabs moved (scroll, reflow, close): what is under a still pointer may differ. Hit testing reads
        // the targets, the frames written above.
        geometryDidChange()
        // A drag, a group drag or a torn-out tab over the strip autoscrolls at an edge; `debug.motion`
        // samples a move's travel while it records.
        if drag != nil || groups.drag != nil || phantomPoint != nil || (move != nil && MotionTrace.isEnabled) { startAnimating() }
    }

    // MARK: - Drag autoscroll

    /// Runs drag autoscroll on the window's one `MotionClock`, and `debug.motion`'s travel samples while
    /// it records. Nothing else in the strip steps per frame.
    func startAnimating() {
        guard window != nil else { return }
        let clock = MotionClock.forView(self)
        if let motionClock, motionClock !== clock { motionClock.stop(self) }
        motionClock = clock
        clock.run(self, trace: "tabs.autoscroll")
    }
}

extension TabStripView: MotionAnimating {
    /// Autoscroll has no end state: out of sight it just stops.
    public func motionSettle() {}

    /// One autoscroll frame; false when no drag sits in an edge fade and no recorded move travels.
    public func motionStep(_ dt: Double) -> Bool {
        let scrolling = autoscrollDuringDrag(CGFloat(dt))
        guard MotionTrace.isEnabled else { return scrolling }
        // `debug.motion` (motion proofs): the points the strip's moves have left to travel (x and width),
        // read off the presentation layers; reading them changes nothing that draws.
        let travel = cells.values.reduce(0.0) { sum, cell in
            guard let shown = cell.layer.presentation() else { return sum }
            return sum + Double(abs(shown.frame.minX - cell.frame.minX) + abs(shown.frame.width - cell.frame.width))
        }
        MotionTrace.sample("tabs.travel", travel)
        return scrolling || travel > 0.25
    }
}

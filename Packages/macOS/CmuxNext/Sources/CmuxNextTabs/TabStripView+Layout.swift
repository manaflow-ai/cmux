import AppKit
public import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore
// Layout, frame application, edge fades, and the FrameScheduler animation client.
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
            Self.insertPlaceholder(placeholder, atTabIndex: max(index, pinnedCount), into: &items)
        }
        return items
    }

    /// Inserts a drop gap before the `tabIndex`-th tab of `items`. The gap
    /// goes before that tab's chip unless it joins that tab's group.
    static func insertPlaceholder(_ placeholder: TabLayoutItem, atTabIndex tabIndex: Int, into items: inout [TabLayoutItem]) {
        var seen = 0
        var position = items.count
        for (offset, item) in items.enumerated() where !item.isGroupChip {
            if seen == tabIndex {
                position = offset
                break
            }
            seen += 1
        }
        if position > 0, items[position - 1].isGroupChip, items[position - 1].groupID != placeholder.groupID {
            position -= 1
        }
        items.insert(placeholder, at: position)
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
        // tab's drop keeps every tween as it was.
        let insertsAtOnce = !added.isEmpty && drag == nil && pendingDrop == nil && !grows
        let tween: MotionTween = grows ? .tabOpen : token ?? .tabMove
        let scale = window?.backingScaleFactor ?? 2
        // The previous tab's right edge as it is on screen now (Chrome StartInsertTabAnimation reads the
        // previous tab's current bounds): a new tab opens there and slides with it to its slot, so the
        // two move in lockstep on the same tween and never overlap (the proof's open overlap and the
        // cx-4t1tc hit test: a slot-based start sat under the still-shrinking previous tab).
        var previousMaxX: CGFloat?
        for slot in result.slots where slot.id != Self.placeholderID {
            defer { previousMaxX = motion[slot.id].map { $0.x.value + $0.width.value } ?? slot.maxX }
            guard var m = motion[slot.id] else { continue }
            if added.contains(slot.id) {
                if let pendingDrop, pendingDrop.id == slot.id {
                    m = TabMotion(x: pendingDrop.x, width: pendingDrop.width, alpha: 1)
                    self.pendingDrop = nil
                } else if grows {
                    // Chrome (StartInsertTabAnimation): from the previous tab's current right edge minus
                    // the open width, that wide, no fade; the first tab starts at its slot. Chrome's 18 is
                    // its tab overlap (a tab 18 wide shows nothing); ours do not overlap, so the token
                    // is 0: the tab opens from nothing at the previous right edge (hq-4e 2026-10-15).
                    let open = metrics.chrome.openStartWidth
                    // A new first tab (index 0) opens at its slot from that width while the old first tab
                    // slides right; only a strip's very first tab is there at once (Chrome).
                    let alone = result.slots.count(where: { $0.id != Self.placeholderID }) == 1
                    m = previousMaxX.map { TabMotion(x: $0 - open, width: open, alpha: 1) }
                        ?? (alone ? TabMotion(x: slot.x, width: slot.width, alpha: 1) : TabMotion(x: slot.x, width: open, alpha: 1))
                } else {
                    m = TabMotion(x: slot.x, width: slot.width, alpha: 1)
                }
            }
            m.use(tween)
            if drag?.id != slot.id { m.x.retarget(groupDragX(for: slot) ?? slot.x, scale: scale) }
            if groups.isDragged(slot.id) { m.x.snap() }
            m.width.retarget(slot.width, scale: scale)
            // Members of a collapsed group shrink into the chip and fade.
            m.alpha.target = slot.isCollapsed ? 0 : 1
            if !animated || (insertsAtOnce && !groups.isDragged(slot.id)) { m.snap() }
            motion[slot.id] = m
        }
        pinClosingTabs()
        scroll.target = TabScrollMath.clamp(scroll.target, contentWidth: result.contentWidth, viewportWidth: viewportWidth)
        if keepsSelectedInView, drag == nil, let slot = model.selectedID.flatMap({ result.slot($0) }) {
            scroll.target = TabScrollMath.offset(revealing: slot, current: scroll.target, contentWidth: result.contentWidth, viewportWidth: viewportWidth,
                                                 margin: metrics.scrollFadeWidth, fixedLeading: scrollMapping.band)
        }
        if !animated {
            scroll.snap()
            for id in dying { removeTab(id) }
        } else if insertsAtOnce {
            // The layout already gave a closing tab's room away: it goes now too, one consistent frame.
            for id in dying { removeTab(id) }
        }
        TabSeparatorVisibility.apply(to: self)
        startAnimating()
        applyFrames()
        updateOverflowHint()
    }

    /// A closing tab's left edge stays on the previous tab's right edge minus the close width (0: our
    /// tabs do not overlap) while it shrinks to that width (Chrome StartRemoveTabAnimation), following
    /// that tab as it resizes. The previous tab is the one left of it when it closed (by order, not by
    /// x: a tab opened meanwhile must not move it a slot); the first tab keeps its x.
    func pinClosingTabs() {
        let closeWidth = metrics.chrome.closeEndWidth
        let scale = window?.backingScaleFactor ?? 2
        for id in dying where id.chipGroupID == nil {
            guard var m = motion[id] else { continue }
            let previousMaxX: CGFloat?
            if let anchor = closingAnchors[id] {
                // The left neighbour's slot, or its own closing geometry when it is closing too.
                previousMaxX = anchor.flatMap { a in result.slot(a)?.maxX ?? motion[a].map { $0.x.target + $0.width.target } }
            } else {
                previousMaxX = result.slots.last { $0.id != Self.placeholderID && $0.x < m.x.target - 0.5 }?.maxX
            }
            m.use(.tabClose)
            m.x.retarget(previousMaxX.map { $0 - closeWidth } ?? m.x.target, scale: scale)
            motion[id] = m
        }
    }

    func reveal(_ id: TabID, animated: Bool) {
        guard let slot = result.slot(id) else { return }
        scroll.target = TabScrollMath.offset(
            revealing: slot,
            current: scroll.target,
            contentWidth: result.contentWidth,
            viewportWidth: viewportWidth,
            margin: metrics.scrollFadeWidth,
            fixedLeading: scrollMapping.band
        )
        if !animated || reduceMotion { scroll.snap() }
        startAnimating()
    }

    /// The strip's scroll mapping now: pinned tabs fixed, unpinned tabs at the scroll's current value.
    var scrollMapping: TabScrollMapping { scrollMapping(offset: scroll.value) }

    /// The scroll mapping of the current layout at `offset` (the target, for settled geometry).
    func scrollMapping(offset: CGFloat) -> TabScrollMapping {
        TabScrollMapping(result: result, viewportWidth: viewportWidth, minimumScrollable: metrics.minActiveTabWidth, offset: offset)
    }

    /// The layer a tab's cell draws in: `tabsClip`'s for a pinned tab, else the clipped scrolling layer.
    func tabsLayer(isPinned: Bool) -> CALayer? {
        isPinned ? tabsClip.layer : scrollingLayer
    }

    func applyFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
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
        var trailing: CGFloat = 0
        for (id, cell) in cells {
            guard let m = motion[id] else { continue }
            let isPinned = cell.item.isPinned
            // A tab pinned or unpinned since it was made moves to its region's layer.
            if let parent = tabsLayer(isPinned: isPinned), cell.layer.superlayer !== parent { parent.addSublayer(cell.layer) }
            let width = max(0, m.width.value)
            let minX = pixel(mapping.viewX(m.x.value, isPinned: isPinned))
            cell.frame = CGRect(x: minX, y: tabY, width: pixel(mapping.viewX(m.x.value + width, isPinned: isPinned)) - minX, height: tabHeight)
            cell.layer.opacity = Float(min(max(m.alpha.value, 0), 1))
            cell.accessibility.setAccessibilityFrameInParentSpace(tabsClip.convert(cell.frame, to: self))
            trailing = max(trailing, m.x.value + width)
        }
        TabOcclusion.apply(cells: cells, selected: model.selectedID.flatMap { dying.contains($0) ? nil : $0 }, in: tabsClip.layer, band: mapping.band)
        for group in groups.chips.keys {
            guard let m = motion[.groupChip(group)] else { continue }
            trailing = max(trailing, m.x.value + max(0, m.width.value))
        }
        applyGroupFrames(offset: offset, tabY: tabY, tabHeight: tabHeight, pixel: pixel)
        let buttonWidth = metrics.newTabButtonWidth
        let buttonX = tabsClip.frame.minX + min(trailing - offset, viewportWidth)
        // Square, centered on the tabs: it keeps its size when the tabs are shorter.
        newTabButton.frame = CGRect(x: pixel(buttonX), y: pixel(tabY + (tabHeight - buttonWidth) / 2), width: buttonWidth, height: buttonWidth)
        updateFadeMask()
        // Tabs moved (scroll, reflow, close): what is under a still pointer may differ.
        geometryDidChange()
    }

    /// Fades the strip's ends only while tabs are hidden beyond them: none
    /// on the leading edge at offset 0, none on the trailing edge at the
    /// end, none when every tab fits (rubber band past an end included). An
    /// edge's band fades in or out with the Motion `hover` token (a short
    /// crossfade under Reduce Motion, per the Motion policy); the mask comes off once no edge is faded, so a
    /// strip that fits renders with no offscreen pass.
    func updateFadeMask() {
        let width = viewportWidth
        let edges = width > 0
            ? TabScrollMath.fadedEdges(offset: scroll.value, contentWidth: result.contentWidth, viewportWidth: width)
            : (leading: false, trailing: false)
        // The leading fade starts after the fixed pinned band, which never fades.
        let band = min(scrollMapping.band, width)
        let fade = min(metrics.scrollFadeWidth, max(0, width - band) / 2) / max(width, 1)
        let start = band / max(width, 1)
        fadeMask.frame = tabsClip.bounds
        fadeMask.locations = [0, start, start, start + fade, 1 - fade, 1].map { NSNumber(value: Double($0)) }
        guard edges != fadedEdges else { return }
        let wasFaded = fadedEdges.leading || fadedEdges.trailing
        let isFaded = edges.leading || edges.trailing
        fadedEdges = edges
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        let colors = [opaque, opaque, edges.leading ? clear : opaque, opaque, opaque, edges.trailing ? clear : opaque]
        if isFaded, tabsClip.layer?.mask !== fadeMask { tabsClip.layer?.mask = fadeMask }
        let animates = window != nil && (wasFaded || isFaded) && !Motion.isLiveResizing // in a live resize the edge follows at once
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { // main-proof: CATransaction.h: the completion block is called on the main thread
                guard let self, !(self.fadedEdges.leading || self.fadedEdges.trailing) else { return }
                if self.tabsClip.layer?.mask != nil { self.tabsClip.layer?.mask = nil }
            }
        }
        if animates {
            // A freshly installed mask starts from fully opaque, not from
            // the colors it had when it came off.
            Motion.set(fadeMask, "colors", to: colors, fade: .hover, from: wasFaded ? nil : Array(repeating: opaque, count: colors.count))
        } else {
            fadeMask.removeAnimation(forKey: "colors")
            Motion.transaction(nil) { fadeMask.colors = colors }
        }
        CATransaction.commit()
    }

    // MARK: - Animation

    func startAnimating() {
        guard window != nil else { return }
        let clock = MotionClock.forView(self)
        if let motionClock, motionClock !== clock { motionClock.stop(self) }
        motionClock = clock
        clock.run(self, trace: "tabs")
    }

    /// One animation frame; false when everything settled.
    @discardableResult
    func advance(_ dt: CGFloat) -> Bool {
        var active = false
        for id in Array(motion.keys) {
            guard var m = motion[id] else { continue }
            if groups.isDragged(id) { m.x.snap() }
            // The dragged tab sits exactly under the pointer; its spring
            // only runs after release.
            if drag?.id != id { m.x.step(dt) }
            m.width.step(dt)
            m.alpha.step(dt)
            motion[id] = m
            if dying.contains(id), m.width.isSettled, m.alpha.isSettled {
                removeTab(id)
            } else if !m.isSettled, drag?.id != id {
                active = true
            }
        }
        if autoscrollDuringDrag(dt) { active = true }
        scroll.step(dt)
        if !scroll.isSettled { active = true }
        if MotionTrace.isEnabled {
            // The points the strip's tabs have left to travel (x and width): its spring's path, for debug.motion.
            MotionTrace.sample("tabs.travel", Double(motion.values.reduce(0) { $0 + abs($1.x.target - $1.x.value) + abs($1.width.target - $1.width.value) }))
        }
        // Tabs sliding under a still pointer update hover (applyFrames ->
        // geometryDidChange).
        applyFrames()
        return active
    }
}

extension TabStripView: MotionAnimating {
    public func motionStep(_ dt: Double) -> Bool { advance(CGFloat(dt)) }
}

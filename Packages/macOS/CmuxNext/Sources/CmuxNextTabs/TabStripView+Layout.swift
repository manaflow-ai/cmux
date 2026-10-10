import AppKit
import CmuxNextDesign
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

    func relayout(animated: Bool, added: Set<TabID> = []) {
        result = TabLayoutEngine.layout(
            items: layoutItems(),
            availableWidth: viewportWidth,
            style: model.style,
            metrics: metrics,
            closingModeWidth: closingModeWidth
        )
        for slot in result.slots where slot.id != Self.placeholderID {
            guard var m = motion[slot.id] else { continue }
            if added.contains(slot.id) {
                if let pendingDrop, pendingDrop.id == slot.id {
                    m = TabMotion(x: pendingDrop.x, width: pendingDrop.width, alpha: 1)
                    self.pendingDrop = nil
                } else {
                    // New tabs grow in from zero width at their slot.
                    m = TabMotion(x: slot.x, width: animated ? 0 : slot.width, alpha: animated ? 0 : 1)
                }
            }
            if drag?.id != slot.id { m.x.target = groupDragX(for: slot) ?? slot.x }
            if groups.isDragged(slot.id) { m.x.snap() }
            m.width.target = slot.width
            // Members of a collapsed group shrink into the chip and fade.
            m.alpha.target = slot.isCollapsed ? 0 : 1
            if !animated { m.snap() }
            motion[slot.id] = m
        }
        scroll.target = TabScrollMath.clamp(scroll.target, contentWidth: result.contentWidth, viewportWidth: viewportWidth)
        if !animated {
            scroll.snap()
            for id in dying { removeTab(id) }
        }
        updateSeparators()
        startAnimating()
        applyFrames()
    }

    func reveal(_ id: TabID, animated: Bool) {
        guard let slot = result.slot(id) else { return }
        scroll.target = TabScrollMath.offset(
            revealing: slot,
            current: scroll.target,
            contentWidth: result.contentWidth,
            viewportWidth: viewportWidth,
            margin: metrics.scrollFadeWidth
        )
        if !animated || reduceMotion { scroll.snap() }
        startAnimating()
    }

    /// Chrome's separator rule (`TabSeparatorVisibility`) over the tabs in the
    /// row: the selected, hovered and dragged tabs hide the separators on
    /// both sides, and the last tab's separator is the line before +. A drop
    /// gap counts as the dragged tab. Members collapsed into a group chip are
    /// out of the row and draw none; a chip is a neutral neighbor.
    func updateSeparators() {
        let row = result.slots.filter { !$0.isCollapsed }
        func index(of id: TabID?) -> Int? { id.flatMap { id in row.firstIndex { $0.id == id } } }
        let visible = TabSeparatorVisibility.visibleSeparators(
            tabCount: row.count,
            selected: index(of: model.selectedID),
            hovered: index(of: hoveredID),
            dragged: index(of: drag?.id) ?? index(of: Self.placeholderID)
        )
        let shown = Set(visible.map { row[$0].id })
        for slot in result.slots {
            cells[slot.id]?.showsSeparator = shown.contains(slot.id)
        }
    }

    func applyFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let tabHeight = min(metrics.tabHeight, bounds.height)
        let tabY = tabTop
        let offset = scroll.value
        let scale = window?.backingScaleFactor ?? 2
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        var trailing: CGFloat = 0
        for (id, cell) in cells {
            guard let m = motion[id] else { continue }
            let width = max(0, m.width.value)
            let minX = pixel(m.x.value - offset)
            cell.frame = CGRect(x: minX, y: tabY, width: pixel(m.x.value - offset + width) - minX, height: tabHeight)
            cell.layer.opacity = Float(min(max(m.alpha.value, 0), 1))
            cell.accessibility.setAccessibilityFrameInParentSpace(tabsClip.convert(cell.frame, to: self))
            trailing = max(trailing, m.x.value + width)
        }
        for group in groups.chips.keys {
            guard let m = motion[.groupChip(group)] else { continue }
            trailing = max(trailing, m.x.value + max(0, m.width.value))
        }
        applyGroupFrames(offset: offset, tabY: tabY, tabHeight: tabHeight, pixel: pixel)
        let buttonWidth = metrics.newTabButtonWidth
        let buttonX = tabsClip.frame.minX + min(trailing - offset, viewportWidth)
        newTabButton.frame = CGRect(x: pixel(buttonX), y: tabY, width: buttonWidth, height: tabHeight)
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
        let fade = min(metrics.scrollFadeWidth / max(width, 1), 0.5)
        fadeMask.frame = tabsClip.bounds
        fadeMask.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
        guard edges != fadedEdges else { return }
        let wasFaded = fadedEdges.leading || fadedEdges.trailing
        let isFaded = edges.leading || edges.trailing
        fadedEdges = edges
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        let colors = [edges.leading ? clear : opaque, opaque, opaque, edges.trailing ? clear : opaque]
        if isFaded, tabsClip.layer?.mask !== fadeMask { tabsClip.layer?.mask = fadeMask }
        let animates = window != nil && (wasFaded || isFaded)
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
            Motion.set(fadeMask, "colors", to: colors, fade: .hover, from: wasFaded ? nil : [opaque, opaque, opaque, opaque])
        } else {
            fadeMask.removeAnimation(forKey: "colors")
            Motion.transaction(nil) { fadeMask.colors = colors }
        }
        CATransaction.commit()
    }

    // MARK: - Animation

    func startAnimating() {
        guard window != nil else { return }
        guard !animationClient.isActive else { return }
        MotionTrace.begin("tabs")
        animationClient.activate()
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
        // Tabs sliding under a still pointer update hover (applyFrames ->
        // geometryDidChange).
        applyFrames()
        if !active { MotionTrace.end("tabs") }
        return active
    }
}

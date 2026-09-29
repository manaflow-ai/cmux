import AppKit
import CmuxNextDesign
import QuartzCore
// Layout, frame application, edge fades, and the display-link animation loop.
extension TabStripView {
    // MARK: - Layout

    func layoutItems() -> [TabLayoutItem] {
        var items = displayed.map { TabLayoutItem(id: $0.id, isPinned: $0.isPinned, isSelected: $0.id == model.selectedID) }
        if let drag, let from = items.firstIndex(where: { $0.id == drag.id }) {
            let item = items.remove(at: from)
            items.insert(item, at: min(max(drag.currentIndex, 0), items.count))
        }
        if let index = dropPlaceholderIndex {
            let pinnedCount = items.count(where: \.isPinned)
            items.insert(TabLayoutItem(id: Self.placeholderID), at: min(max(index, pinnedCount), items.count))
        }
        return items
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
                    m = Motion(x: pendingDrop.x, width: pendingDrop.width, alpha: 1)
                    self.pendingDrop = nil
                } else {
                    // New tabs grow in from zero width at their slot.
                    m = Motion(x: slot.x, width: animated ? 0 : slot.width, alpha: animated ? 0 : 1)
                }
            }
            if drag?.id != slot.id { m.x.target = slot.x }
            m.width.target = slot.width
            m.alpha.target = 1
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

    func updateSeparators() {
        let slots = result.slots
        let selected = model.selectedID
        func emphasized(_ id: TabID) -> Bool {
            id == selected || id == hoveredID || id == drag?.id || id == Self.placeholderID
        }
        for (index, slot) in slots.enumerated() {
            guard let view = tabViews[slot.id] else { continue }
            guard index + 1 < slots.count else {
                view.showsSeparator = false
                continue
            }
            let next = slots[index + 1]
            view.showsSeparator = !emphasized(slot.id) && !emphasized(next.id) && slot.isPinned == next.isPinned
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
        for (id, view) in tabViews {
            guard let m = motion[id] else { continue }
            let width = max(0, m.width.value)
            let minX = pixel(m.x.value - offset)
            let frame = CGRect(x: minX, y: tabY, width: pixel(m.x.value - offset + width) - minX, height: tabHeight)
            if view.frame != frame {
                let resized = view.frame.size != frame.size
                view.frame = frame
                if resized { view.layoutLayers() }
            }
            view.layer?.opacity = Float(min(max(m.alpha.value, 0), 1))
            trailing = max(trailing, m.x.value + width)
        }
        let buttonWidth = metrics.newTabButtonWidth
        let buttonX = tabsClip.frame.minX + min(trailing - offset, viewportWidth)
        newTabButton.frame = CGRect(x: pixel(buttonX), y: tabY, width: buttonWidth, height: tabHeight)
        updateFadeMask()
    }

    func updateFadeMask() {
        let width = viewportWidth
        let edges = TabScrollMath.fadedEdges(offset: scroll.value, contentWidth: result.contentWidth, viewportWidth: width)
        guard width > 0, edges.leading || edges.trailing else {
            if tabsClip.layer?.mask != nil { tabsClip.layer?.mask = nil }
            return
        }
        let fade = min(metrics.scrollFadeWidth / width, 0.5)
        fadeMask.frame = tabsClip.bounds
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        fadeMask.colors = [edges.leading ? clear : opaque, opaque, opaque, edges.trailing ? clear : opaque]
        fadeMask.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
        if tabsClip.layer?.mask !== fadeMask { tabsClip.layer?.mask = fadeMask }
    }

    // MARK: - Animation

    func startAnimating() {
        guard window != nil else { return }
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc func displayLinkFired(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastFrameTime.map { CGFloat(now - $0) } ?? (1.0 / 120.0)
        lastFrameTime = now
        advance(dt)
    }

    func advance(_ dt: CGFloat) {
        var active = false
        for id in Array(motion.keys) {
            guard var m = motion[id] else { continue }
            if drag?.id == id { m.x.snap() }
            m.x.step(dt)
            m.width.step(dt)
            m.alpha.step(dt)
            motion[id] = m
            if dying.contains(id), m.width.isSettled, m.alpha.isSettled {
                removeTab(id)
            } else if !m.isSettled {
                active = true
            }
        }
        if autoscrollDuringDrag(dt) { active = true }
        scroll.step(dt)
        if !scroll.isSettled { active = true }
        applyFrames()
        if drag == nil, pressedCloseID == nil, let window {
            // Tabs sliding under a still pointer update hover, as in Chrome.
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { updateHover(at: point) }
        }
        if !active {
            displayLink?.isPaused = true
            lastFrameTime = nil
        }
    }
}

public import AppKit
import CmuxNextDesign
import QuartzCore
// Hit testing, hover, clicks, context menu, and wheel scrolling.
extension TabStripView {
    // MARK: - Hit testing

    func tabID(at point: CGPoint) -> TabID? {
        let local = convert(point, to: tabsClip)
        guard local.x >= 0, local.x <= tabsClip.bounds.width else { return nil }
        for item in displayed {
            guard let view = tabViews[item.id] else { continue }
            let frame = view.frame
            // The full strip height is the hit area, not just the tab body.
            if local.x >= frame.minX, local.x < frame.maxX, local.y >= 0, local.y <= tabsClip.bounds.height {
                return item.id
            }
        }
        return nil
    }

    func isInCloseButton(_ id: TabID, _ point: CGPoint) -> Bool {
        guard let view = tabViews[id], let rect = view.closeButtonRect else { return false }
        return rect.insetBy(dx: -2, dy: -2).contains(convert(point, to: view))
    }

    func isInNewTabButton(_ point: CGPoint) -> Bool {
        !newTabButton.isHidden && newTabButton.frame.contains(convert(point, to: contentView))
    }

    // MARK: - Hover

    func setHovered(_ id: TabID?) {
        guard id != hoveredID else { return }
        if let hoveredID { tabViews[hoveredID]?.isHovered = false }
        hoveredID = id
        if let id { tabViews[id]?.isHovered = true }
        updateSeparators()
    }

    func updateHover(at point: CGPoint) {
        // No hover (or hover card) while any drag involves this strip.
        let dragging = drag != nil || detachedID != nil || dropPlaceholderIndex != nil
        let id = dragging ? nil : tabID(at: point)
        setHovered(id)
        let closeID = id.flatMap { isInCloseButton($0, point) ? $0 : nil }
        if closeID != closeHoveredID {
            if let closeHoveredID { tabViews[closeHoveredID]?.isCloseHovered = false }
            closeHoveredID = closeID
            if let closeID { tabViews[closeID]?.isCloseHovered = true }
        }
        newTabButton.isHovered = !dragging && isInNewTabButton(point)

        guard !hoverCardSuppressed else { return }
        if let id, let item = model.tab(id), let view = tabViews[id], let window, NSApp.isActive {
            let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
            hoverCard.hover(item, anchor: anchor, tabWidth: view.bounds.width, parent: window)
        } else {
            hoverCard.hide()
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        hoverCardSuppressed = false
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        setHovered(nil)
        if let closeHoveredID { tabViews[closeHoveredID]?.isCloseHovered = false }
        closeHoveredID = nil
        newTabButton.isHovered = false
        hoverCard.hide()
        hoverCardSuppressed = false
        if closingModeWidth != nil, drag == nil {
            // Chrome's deferred relayout: tabs resize once the pointer leaves.
            closingModeWidth = nil
            relayout(animated: !reduceMotion)
        }
    }

    // MARK: - Clicks

    public override func mouseDown(with event: NSEvent) {
        hoverCard.hide(allowsQuickReshow: false)
        hoverCardSuppressed = true
        let point = convert(event.locationInWindow, from: nil)
        if isInNewTabButton(point) {
            pressedNewTab = true
            newTabButton.isPressed = true
            return
        }
        if let id = tabID(at: point) {
            if isInCloseButton(id, point) {
                pressedCloseID = id
                tabViews[id]?.isClosePressed = true
                return
            }
            // Chrome selects on mouse down.
            if model.selectedID != id { model.send(.select(id)) }
            press = Press(id: id, start: point)
            return
        }
        if event.clickCount == 2 {
            model.send(.newTab(after: nil))
            return
        }
        if dragsWindowFromEmptySpace { window?.performDrag(with: event) }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = pressedCloseID {
            tabViews[id]?.isClosePressed = isInCloseButton(id, point)
            return
        }
        if pressedNewTab {
            newTabButton.isPressed = isInNewTabButton(point)
            return
        }
        if drag != nil {
            updateDrag(at: point, event: event)
            return
        }
        if let press, hypot(point.x - press.start.x, point.y - press.start.y) > Metrics.space2 {
            beginDrag(press)
            updateDrag(at: point, event: event)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = pressedCloseID {
            pressedCloseID = nil
            tabViews[id]?.isClosePressed = false
            if isInCloseButton(id, point) { close(id, source: .mouse) }
            return
        }
        if pressedNewTab {
            pressedNewTab = false
            newTabButton.isPressed = false
            if isInNewTabButton(point) { model.send(.newTab(after: nil)) }
            return
        }
        if drag != nil { endDrag() }
        press = nil
        updateHover(at: point)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        hoverCard.hide(allowsQuickReshow: false)
        middlePressID = tabID(at: convert(event.locationInWindow, from: nil))
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let id = tabID(at: convert(event.locationInWindow, from: nil))
        if let id, id == middlePressID { close(id, source: .middleClick) }
        middlePressID = nil
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        hoverCard.hide(allowsQuickReshow: false)
        let point = convert(event.locationInWindow, from: nil)
        if let id = tabID(at: point), let item = model.tab(id) {
            return TabContextMenu.menu(for: item, in: model)
        }
        return TabContextMenu.emptySpaceMenu(in: model)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard result.isOverflowing else { return super.scrollWheel(with: event) }
        var delta = event.scrollingDeltaX
        // Vertical wheels scroll the strip too, as in Chrome.
        if abs(event.scrollingDeltaY) > abs(delta) { delta = event.scrollingDeltaY }
        if !event.hasPreciseScrollingDeltas { delta *= 12 }
        scroll.snap(to: TabScrollMath.clamp(scroll.value - delta, contentWidth: result.contentWidth, viewportWidth: viewportWidth))
        hoverCard.hide(allowsQuickReshow: false)
        applyFrames()
    }

    /// Closes a tab. Mouse closes enter Chrome's closing mode first.
    func close(_ id: TabID, source: TabCloseSource) {
        if source.entersClosingMode {
            closingModeWidth = TabLayoutEngine.closingModeWidth(afterClosing: id, in: result, current: closingModeWidth)
        }
        model.send(.close(id, source: source))
    }
}

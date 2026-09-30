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
            guard let cell = cells[item.id], cell.frame.width > 0.5 else { continue }
            let frame = cell.frame
            // The full strip height is the hit area, not just the tab body.
            if local.x >= frame.minX, local.x < frame.maxX, local.y >= 0, local.y <= tabsClip.bounds.height {
                return item.id
            }
        }
        return nil
    }

    func isInCloseButton(_ id: TabID, _ point: CGPoint) -> Bool {
        guard let cell = cells[id], let rect = cell.closeButtonRect else { return false }
        let local = convert(point, to: tabsClip)
        let inCell = CGPoint(x: local.x - cell.frame.minX, y: local.y - cell.frame.minY)
        return rect.insetBy(dx: -2, dy: -2).contains(inCell)
    }

    func isInNewTabButton(_ point: CGPoint) -> Bool {
        !newTabButton.isHidden && newTabButton.frame.contains(convert(point, to: contentView))
    }

    // MARK: - Hover

    func setHovered(_ id: TabID?) {
        guard id != hoveredID else { return }
        if let hoveredID { cells[hoveredID]?.isHovered = false }
        hoveredID = id
        if let id { cells[id]?.isHovered = true }
        updateSeparators()
    }

    func updateHover(at point: CGPoint) {
        // No hover (or hover card) while any drag involves this strip.
        let dragging = drag != nil || detachedID != nil || dropPlaceholderIndex != nil
            || groups.drag != nil || groups.detachedGroupID != nil
        let chip = dragging ? nil : chipGroup(at: point)
        let id = dragging || chip != nil ? nil : tabID(at: point)
        setHovered(id)
        setHoveredChip(chip)
        let closeID = id.flatMap { isInCloseButton($0, point) ? $0 : nil }
        if closeID != closeHoveredID {
            if let closeHoveredID { cells[closeHoveredID]?.isCloseHovered = false }
            closeHoveredID = closeID
            if let closeID { cells[closeID]?.isCloseHovered = true }
        }
        newTabButton.isHovered = !dragging && isInNewTabButton(point)
        buttonGroup.hoveredIndex = dragging ? nil : trailingButtonIndex(at: point)

        guard !hoverCardSuppressed, !groupEditor.isVisible else { return }
        if let chip {
            hoverChip(chip)
        } else if let id, let item = model.tab(id), let cell = cells[id], let window, NSApp.isActive {
            let anchor = window.convertToScreen(tabsClip.convert(cell.frame, to: nil))
            hoverCard.hover(.tab(item), anchor: anchor, tabWidth: cell.frame.width, parent: window)
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
        setHoveredChip(nil)
        if let closeHoveredID { cells[closeHoveredID]?.isCloseHovered = false }
        closeHoveredID = nil
        newTabButton.isHovered = false
        buttonGroup.hoveredIndex = nil
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
            startNewTabHold()
            return
        }
        if let index = trailingButtonIndex(at: point) {
            pendingTrailingPress = index
            buttonGroup.pressedIndex = index
            return
        }
        if let group = chipGroup(at: point) {
            groups.press = TabStripGroupState.Press(groupID: group, start: point)
            groups.chips[group]?.isPressed = true
            startChipHold(group)
            return
        }
        if let id = tabID(at: point) {
            if isInCloseButton(id, point) {
                pressedCloseID = id
                cells[id]?.isClosePressed = true
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
            cells[id]?.isClosePressed = isInCloseButton(id, point)
            return
        }
        if pressedNewTab {
            newTabButton.isPressed = isInNewTabButton(point)
            return
        }
        if trackTrailingButtonDrag(at: point) { return }
        if drag != nil {
            updateDrag(at: point, event: event)
            return
        }
        if groups.drag != nil {
            updateGroupDrag(at: point, event: event)
            return
        }
        if let press = groups.press, !press.openedEditor, hypot(point.x - press.start.x, point.y - press.start.y) > Metrics.space2 {
            beginGroupDrag(press)
            updateGroupDrag(at: point, event: event)
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
            cells[id]?.isClosePressed = false
            if isInCloseButton(id, point) { close(id, source: .mouse) }
            return
        }
        if endNewTabPress(at: point) { return }
        if endTrailingButtonPress(at: point) { return }
        if drag != nil { endDrag() }
        press = nil
        if groups.drag != nil {
            endGroupDrag()
        } else if let press = groups.press {
            groups.chips[press.groupID]?.isPressed = false
            if !press.openedEditor, chipGroup(at: point) == press.groupID {
                model.send(.toggleGroupCollapsed(press.groupID))
            }
        }
        groups.press = nil
        groups.holdTask?.cancel()
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
        if trailingButtonIndex(at: point) != nil { return nil }
        if isInNewTabButton(point) {
            // Anchored under the button, like the press-and-hold menu.
            showNewTabMenu()
            return nil
        }
        if let group = chipGroup(at: point) {
            if let menu = contextMenuProvider?(.group(group)) { return menu }
            showGroupEditor(for: group)
            return nil
        }
        if let id = tabID(at: point) {
            return contextMenuProvider?(.tab(id, selection: [id]))
        }
        return contextMenuProvider?(.emptyStrip)
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

    /// Mouse-up after a press on +. Returns whether the press was on +.
    /// Chrome: a click opens a tab at once; a hold already showed the menu
    /// and must not also open a tab.
    @discardableResult
    func endNewTabPress(at point: CGPoint) -> Bool {
        newTabHoldTask?.cancel()
        newTabHoldTask = nil
        defer { newTabHoldOpenedMenu = false }
        guard pressedNewTab else { return newTabHoldOpenedMenu }
        pressedNewTab = false
        newTabButton.isPressed = false
        if !newTabHoldOpenedMenu, isInNewTabButton(point) { model.send(.newTab(after: nil)) }
        return true
    }

    /// Holding + opens the new tab menu, like Safari's back button history.
    func startNewTabHold() {
        newTabHoldTask?.cancel()
        newTabHoldOpenedMenu = false
        let sleep = groups.sleep
        newTabHoldTask = Task { [weak self] in
            do { try await sleep(.milliseconds(450)) } catch { return }
            guard let self, !Task.isCancelled, self.pressedNewTab else { return }
            self.newTabHoldOpenedMenu = true
            self.newTabButton.isPressed = false
            self.pressedNewTab = false
            self.showNewTabMenu()
        }
    }

    /// The new tab menu (which kind of tab: terminal, WebKit, Chromium)
    /// under the + button. Right-click and press-and-hold open it; a plain
    /// click opens a terminal tab.
    func showNewTabMenu() {
        guard let menu = contextMenuProvider?(.newTabButton), !menu.items.isEmpty else { return }
        hoverCard.hide(allowsQuickReshow: false)
        let frame = convert(newTabButton.frame, from: newTabButton.superview)
        let origin = NSPoint(x: frame.minX, y: isFlipped ? frame.maxY + 2 : frame.minY - 2)
        menu.popUp(positioning: nil, at: origin, in: self)
    }

    /// Closes a tab. Mouse closes enter Chrome's closing mode first.
    func close(_ id: TabID, source: TabCloseSource) {
        if source.entersClosingMode {
            closingModeWidth = TabLayoutEngine.closingModeWidth(afterClosing: id, in: result, current: closingModeWidth)
        }
        model.send(.close(id, source: source))
    }
}

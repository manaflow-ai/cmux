public import AppKit
import CmuxNextDesign
public import CmuxNextInput
public import CmuxNextWakeups
import QuartzCore
// Hit testing, hover, clicks, context menu, and wheel scrolling.
extension TabStripView {
    // MARK: - Hit testing

    func tabID(at point: CGPoint) -> TabID? {
        let local = convert(point, to: tabsClip)
        guard local.x >= 0, local.x <= tabsClip.bounds.width else { return nil }
        // An unpinned tab scrolled under the fixed pinned band is hidden there: only pinned tabs hit.
        let showsUnpinned = scrollMapping.showsUnpinned(at: local.x)
        for item in displayed where item.isPinned || showsUnpinned {
            guard let cell = cells[item.id], cell.frame.width > 0.5 else { continue }
            let frame = scroller.shownFrame(cell.layer) // where it shows, the scroll's translation included
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
        let inCell = CGPoint(x: local.x - scroller.shownFrame(cell.layer).minX, y: local.y - cell.frame.minY)
        return rect.insetBy(dx: -2, dy: -2).contains(inCell)
    }

    /// Whether `point` (strip coordinates) is on tab `id`'s speaker, with a
    /// little slack around the small glyph.
    func isInAudioButton(_ id: TabID, _ point: CGPoint) -> Bool {
        // The close button wins where the slack reaches it.
        guard let cell = cells[id], let rect = cell.audioButtonRect, !isInCloseButton(id, point) else { return false }
        let local = convert(point, to: tabsClip)
        let inCell = CGPoint(x: local.x - scroller.shownFrame(cell.layer).minX, y: local.y - cell.frame.minY)
        return rect.insetBy(dx: -3, dy: -4).contains(inCell)
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
        onHoverTab?(id)
        TabSeparatorVisibility.apply(to: self)
    }

    /// `moved`: a pointer event (true) or content that moved under a still
    /// pointer (false, `geometryDidChange`).
    func updateHover(at point: CGPoint, moved: Bool) {
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
        setAudioHovered(id.flatMap { isInAudioButton($0, point) ? $0 : nil })
        newTabButton.isHovered = !dragging && isInNewTabButton(point)

        // The coordinator hit-tests the pointer itself (`TabHoverCardController.target`).
        if moved, let window { hoverCards.pointerMoved(to: window.convertPoint(toScreen: convert(point, to: nil))) }
    }

    /// The speaker under the pointer: its fill, and a tooltip naming what a click does.
    func setAudioHovered(_ id: TabID?) {
        if id != audioHoveredID {
            if let audioHoveredID { cells[audioHoveredID]?.isAudioHovered = false }
            audioHoveredID = id
            if let id { cells[id]?.isAudioHovered = true }
        }
        let tip = id.flatMap { cells[$0]?.item.audio }.map { $0 == .muted ? Strings.unmuteTab : Strings.muteTab }
        // tooltip-native-allow: the strip's speakers are layers, not views; a themed tracker added while the
        // pointer is already inside gets no mouseEntered, and one anchors below the whole strip.
        if toolTip != tip { toolTip = tip }
    }

    /// Shows tab `id`'s hover card now (with its CPU and memory) until the
    /// next key press, click or scroll. False when the tab has no visible
    /// cell or the window is hidden.
    @discardableResult
    public func showHoverCard(for id: TabID) -> Bool {
        guard model.tab(id) != nil, let cell = cells[id], cell.frame.width > 0.5, let window else { return false }
        let target = HoverTarget(id: TabHoverCardController.targetID(id), window: window.windowNumber,
                                 delay: hoverCard.delay, leave: hoverCard.leave)
        hoverCards.pin(target, from: hoverCard)
        return hoverCards.isShowing(target.id)
    }

    // Enter and exit are discrete: the pending moves land first (Chromium's `ShouldFlushQueue`).
    public override func mouseEntered(with event: NSEvent) {
        frameInputHover.flush()
        if closingWatch.trackingEvent(event, entered: true) { return }
        buttonReveal.pointerInStrip = true
        closingWatch.pointerReturned()
        updateHover(at: convert(event.locationInWindow, from: nil), moved: true)
    }

    /// The windows' frame-aligned pointer input (feature `pointerFrameHover`): a frame interval's first move
    /// hovers at once and the rest once at its frame, at the latest point. Nil: each move hovers at once.
    public var hoverFrameInput: FrameInputCoalescers? {
        get { frameInputHover.frames }
        set { frameInputHover.frames = newValue }
    }

    /// The windows' frame-aligned wheels (feature `tabStripScrollFrames`): a frame's wheel and trackpad
    /// deltas move one layer at most twice per frame (`TabStripScroller`). Nil: each scroll event lays out.
    public var scrollFrameInput: FrameInputCoalescers? {
        get { scroller.frames }
        set { scroller.frames = newValue }
    }

    /// A move hovers on its frame interval's leading edge or once at the frame with `hoverFrameInput`,
    /// at the latest point, as Chromium delivers rAF-aligned mouse moves
    /// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`); without it, at once.
    public override func mouseMoved(with event: NSEvent) {
        frameInputHover.moved(event)
    }

    /// One hover delivery: the point is converted now, so a strip that scrolled since the move
    /// hit-tests its tabs where they show now (`TabStripScroller.shownFrame`). The pointer is in the strip, so its plus shows.
    func hoverMoved(toWindowPoint point: CGPoint) {
        buttonReveal.pointerInStrip = true
        updateHover(at: convert(point, from: nil), moved: true)
    }

    public override func mouseExited(with event: NSEvent) {
        frameInputHover.flush()
        if closingWatch.trackingEvent(event, entered: false) { return }
        pointerLeft()
        hoverCards.pointerMoved(to: window.map { $0.convertPoint(toScreen: event.locationInWindow) })
    }

    /// cmux resigned active while the pointer was in the strip (`TabStripRevealController`): the
    /// strip's `.activeForHover` area hears no exit then, so its hover ends here. Mouse closing mode
    /// keeps its own exit watch, which hears the leave while cmux is inactive (`TabClosingModeWatch`).
    func endHoverOnDeactivation() {
        buttonReveal.pointerInStrip = false
        clearHover()
        newTabButton.isHovered = false
    }

    /// An exit, or the strip moved away under a still pointer (`geometryDidChange`).
    func pointerLeft() {
        buttonReveal.pointerInStrip = false
        clearHover()
        newTabButton.isHovered = false
        // Deferred relayout: tabs resize once the pointer has left the extended strip for the delay.
        if closingModeWidth != nil, drag == nil { closingWatch.pointerLeft() }
    }

    // MARK: - Clicks

    public override func mouseDown(with event: NSEvent) {
        // The frame's pending scroll and hover land first, so the press acts on the tab under its own point.
        scroller.landForInput()
        frameInputHover.flush()
        dragMoves.began()
        hoverCards.dismiss(.action)
        let point = convert(event.locationInWindow, from: nil)
        // A press before the strip's model sync (right after a close) catches up first.
        if model.orderedTabs.map(\.id) != lastModelOrder { sync(fromModel: true) }
        if !isInNewTabButton(point), let id = arrivingCloseTab(at: point) {
            pressedCloseID = id
            cells[id]?.isClosePressed = true
            return
        }
        if isInNewTabButton(point) {
            if opensNewTabMenuOnPress, !event.modifierFlags.contains(.option) {
                showNewTabMenu()
                return
            }
            pressedNewTab = true
            newTabButton.isPressed = true
            newTabHold.start()
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
            // The speaker is a button: the press neither selects nor drags the
            // tab, and the release on it mutes or unmutes (Chrome).
            if isInAudioButton(id, point) {
                pressedAudioID = id
                cells[id]?.isAudioPressed = true
                return
            }
            // The first click selected the tab; the second renames it (the screen bar) or zooms its pane.
            if event.clickCount == 2, Self.selectionClick(event.modifierFlags) == .plain {
                if renamesOnDoubleClick { beginInlineRename(id) } else { model.send(.toggleZoom(id)) }
                return
            }
            // Select on mouse down; Cmd and Shift add to the selection (`selectOnPress`).
            press = TabStripPress(id: id, start: point)
            selectOnPress(id, modifiers: event.modifierFlags)
            return
        }
        // Empty strip space does nothing here: only the + button opens a tab
        // (Leo 2026-10-12). In the window's top row it is the titlebar, which
        // the window already moved or ran its double-click action for
        // (`TitlebarDragPolicy`).
    }

    // local-monitor-allow: a drag is delivered unbuffered until its mouse-up (p06-scheduler.md section E, FrameInputCoalescer); each move moves the dragged tab or a pressed button's state
    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = pressedCloseID {
            cells[id]?.isClosePressed = isInCloseButton(id, point) || arrivingCloseTab(at: point) == id
            return
        }
        if pressedNewTab {
            newTabButton.isPressed = isInNewTabButton(point)
            return
        }
        if let id = pressedAudioID {
            cells[id]?.isAudioPressed = isInAudioButton(id, point)
            return
        }
        if drag != nil || groups.drag != nil {
            guard isPastTearOff(point) else { return dragMoves.dragged(event) }
            // The tear-off hands the drag to the App's session at this event's point: the frame's pending point is stale.
            dragMoves.cancel()
            return drag != nil ? updateDrag(at: point, event: event) : updateGroupDrag(at: point, event: event)
        }
        if let press = groups.press, !press.openedEditor, hypot(point.x - press.start.x, point.y - press.start.y) > TabTunables.dragStartDistance.value {
            beginGroupDrag(press)
            updateGroupDrag(at: point, event: event)
            return
        }
        if let press, hypot(point.x - press.start.x, point.y - press.start.y) > TabTunables.dragStartDistance.value {
            beginDrag(press)
            updateDrag(at: point, event: event)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        dragMoves.ended() // the frame's pending point lands before the drop
        let point = convert(event.locationInWindow, from: nil)
        if let id = pressedCloseID {
            pressedCloseID = nil
            cells[id]?.isClosePressed = false
            if isInCloseButton(id, point) || arrivingCloseTab(at: point) == id { close(id, source: .mouse, at: point) }
            return
        }
        if let id = pressedAudioID {
            pressedAudioID = nil
            cells[id]?.isAudioPressed = false
            if isInAudioButton(id, point) { model.send(.toggleAudioMute(id)) }
            updateHover(at: point, moved: false)
            return
        }
        if endNewTabPress(at: point, modifiers: event.modifierFlags) { return }
        if drag != nil { endDrag() }
        if press?.collapsesSelection == true { model.clearMultiSelection() }
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
        chipHold.cancel()
        // A click is not a pointer move: the card stays dismissed (quiet).
        updateHover(at: point, moved: false)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        scroller.landForInput()
        hoverCards.dismiss(.action)
        middlePressID = tabID(at: convert(event.locationInWindow, from: nil))
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let id = tabID(at: convert(event.locationInWindow, from: nil))
        if let id, id == middlePressID { close(id, source: .middleClick) }
        middlePressID = nil
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = contextMenu(for: event)
        if let menu { menuTracking.begin(menu) }
        return menu
    }

    private func contextMenu(for event: NSEvent) -> NSMenu? {
        scroller.landForInput()
        hoverCards.dismiss(.action)
        let point = convert(event.locationInWindow, from: nil)
        if isInNewTabButton(point) {
            // Anchored under the button, like the press-and-hold menu.
            showNewTabMenu()
            return nil
        }
        if let group = chipGroup(at: point) {
            // The group editor bubble, as Chrome's (Lawrence 2026-10-14); Option-right-click keeps the full menu.
            if event.modifierFlags.contains(.option), let menu = contextMenuProvider?(.group(group)) { return menu }
            showGroupEditor(for: group)
            return nil
        }
        if let id = tabID(at: point) {
            return contextMenuProvider?(.tab(id, selection: model.contextSelection(for: id)))
        }
        return contextMenuProvider?(.emptyStrip)
    }

    /// An overflowing strip scrolls (`TabStripScroller`); one whose tabs fit passes the event up.
    // local-monitor-allow: the deltas go through the window's FrameInputCoalescer (TabStripScroller, feature tabStripScrollFrames); an event it does not take is forwarded up unchanged
    public override func scrollWheel(with event: NSEvent) {
        if !scroller.scrollWheel(event) { super.scrollWheel(with: event) }
    }

    /// Mouse-up after a press on +. Returns whether the press was on +.
    /// A click opens a tab at once; a hold already showed the menu
    /// and must not also open a tab.
    @discardableResult
    func endNewTabPress(at point: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        let holdOpenedMenu = newTabHold.end()
        guard pressedNewTab else { return holdOpenedMenu }
        pressedNewTab = false
        newTabButton.isPressed = false
        if !holdOpenedMenu, isInNewTabButton(point) { model.send(.newTab(after: nil, sameKind: modifiers.contains(.option))) }
        return true
    }

    /// The pane type menu under +. Pane strips open it on press; other strips
    /// retain their hold and right-click entry points.
    func showNewTabMenu() {
        guard let menu = contextMenuProvider?(.newTabButton), !menu.items.isEmpty else { return }
        hoverCards.dismiss(.action)
        let origin = CmuxPopoverAnchor.menuPoint(for: newTabButton, in: self, gap: 2)
        menuTracking.begin(menu)
        presentNewTabMenu(menu, origin, self)
        menuTracking.end()
    }

    /// Closes a tab once (a tab the model dropped is closing already). Mouse closes enter
    /// closing mode first; `point` is the close button press (`TabClosingModeHit`).
    func close(_ id: TabID, source: TabCloseSource, at point: CGPoint? = nil) {
        guard model.tab(id) != nil else { return }
        if source.entersClosingMode {
            closingModeWidth = TabLayoutEngine.closingModeWidth(afterClosing: id, in: result, current: closingModeWidth)
            if let point, let frame = TabClosingModeHit.laidOut(self).first(where: { $0.id == id })?.frame {
                closingHit.closePressed(at: convert(point, to: tabsClip), on: frame)
            }
        }
        model.send(.close(id, source: source))
    }

    /// In closing mode, the tab whose close button is arriving under `point`.
    func arrivingCloseTab(at point: CGPoint) -> TabID? {
        closingModeWidth == nil ? nil : closingHit.tab(at: convert(point, to: tabsClip), in: self)
    }
}

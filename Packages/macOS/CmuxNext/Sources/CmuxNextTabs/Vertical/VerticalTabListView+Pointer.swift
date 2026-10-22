public import AppKit
import CmuxNextDesign

/// What a press in the vertical tab list landed on; its release decides (`mouseUp`).
struct VerticalTabPress: Equatable {
    enum Target: Equatable {
        case tab(TabID)
        case close(TabID)
        case audio(TabID)
        case header(TabGroupID)
        case newTab
    }

    var target: Target
    var start: CGPoint
    /// A plain press on one of several selected tabs keeps them for a drag; its release selects that tab alone.
    var collapsesSelection = false
}

/// A row being dragged to a new place (`VerticalTabDrop`).
struct VerticalTabDrag: Equatable {
    var id: TabID
    var isActive = true
    var slot: VerticalTabListLayout.Slot?
}

// Hover, clicks, the context menus, drag reorder and wheel scrolling.
extension VerticalTabListView {
    // MARK: Hover

    func updateHover(at point: CGPoint) {
        guard drag == nil else { return }
        let content = contentPoint(point)
        let row = bounds.contains(point) ? listLayout.row(at: content) : nil
        let kind = row?.kind == .separator ? nil : row?.kind
        var changed = kind != hovered
        hovered = kind
        let close = row.flatMap { row in closeFrame(row)?.insetBy(dx: -2, dy: -2).contains(content) == true ? Self.tabID(row.kind) : nil }
        let audio = close == nil ? row.flatMap { row in audioFrame(row)?.contains(content) == true ? Self.tabID(row.kind) : nil } : nil
        changed = changed || close != hoveredClose || audio != hoveredAudio
        hoveredClose = close
        hoveredAudio = audio
        if changed { needsDisplay = true }
    }

    static func tabID(_ kind: VerticalTabListLayout.RowKind) -> TabID? {
        switch kind {
        case .tab(let id), .pinned(let id): id
        default: nil
        }
    }

    func clearHover() {
        guard hovered != nil || hoveredClose != nil || hoveredAudio != nil else { return }
        hovered = nil
        hoveredClose = nil
        hoveredAudio = nil
        needsDisplay = true
    }

    public override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
        pointerEntered()
    }

    public override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
        pointerEntered()
    }

    public override func mouseExited(with event: NSEvent) {
        if drag == nil { clearHover() }
        guard menuEndObserver == nil else { return }
        pointerExited()
    }

    // MARK: Clicks

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        let content = contentPoint(point)
        drag = nil
        guard let row = listLayout.row(at: content) else {
            press = nil
            return
        }
        switch row.kind {
        case .tab(let id):
            if closeFrame(row)?.insetBy(dx: -2, dy: -2).contains(content) == true {
                press = VerticalTabPress(target: .close(id), start: point)
            } else if audioFrame(row)?.contains(content) == true {
                // The speaker is a button: the press neither selects nor drags the tab (Chrome).
                press = VerticalTabPress(target: .audio(id), start: point)
            } else {
                press = VerticalTabPress(target: .tab(id), start: point)
                selectOnPress(id, modifiers: event.modifierFlags)
            }
        case .pinned(let id):
            press = VerticalTabPress(target: .tab(id), start: point)
            selectOnPress(id, modifiers: event.modifierFlags)
        case .groupHeader(let group):
            press = VerticalTabPress(target: .header(group), start: point)
        case .newTab:
            press = VerticalTabPress(target: .newTab, start: point)
        case .separator:
            press = nil
        }
        needsDisplay = true
    }

    /// A press on tab `id`, as the strip's (`TabStripView.selectOnPress`): Cmd toggles it in the
    /// selection, Shift selects a range, and a plain press on one of several selected tabs keeps them.
    func selectOnPress(_ id: TabID, modifiers: NSEvent.ModifierFlags) {
        let click = TabStripView.selectionClick(modifiers)
        if click == .plain, model.multiSelection.isMultiple, model.multiSelection.contains(id) {
            press?.collapsesSelection = true
            if model.selectedID != id { model.send(.select(id)) }
            return
        }
        if let next = model.click(id, click), next != model.selectedID { model.send(.select(next)) }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let press else { return }
        switch press.target {
        case .tab(let id):
            if drag == nil {
                guard hypot(point.x - press.start.x, point.y - press.start.y) > TabTunables.dragStartDistance.value else { return }
                drag = VerticalTabDrag(id: id)
                hoverTimer.cancel()
            }
            autoscroll(toward: point)
            if let item = model.tab(id) { drag?.slot = listLayout.slot(at: contentPoint(point), dragging: item) }
            needsDisplay = true
        default:
            updateHover(at: point)
        }
    }

    /// While a drag holds the pointer past the top or bottom edge, the list scrolls that way.
    private func autoscroll(toward point: CGPoint) {
        let zone = metrics.rowHeight / 2
        let step: CGFloat = point.y < zone ? -(zone - point.y) / 2 : point.y > bounds.height - zone ? (point.y - bounds.height + zone) / 2 : 0
        guard step != 0 else { return }
        scrollOffset += step
        clampScroll()
    }

    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let content = contentPoint(point)
        let released = press
        let dragged = drag
        press = nil
        drag = nil
        defer {
            updateHover(at: point)
            collapseIfPointerLeft()
            needsDisplay = true
        }
        guard let released else { return }
        let row = listLayout.row(at: content)
        switch released.target {
        case .close(let id):
            if let row, row.kind == .tab(id), closeFrame(row)?.insetBy(dx: -2, dy: -2).contains(content) == true {
                model.send(.close(id, source: .mouse))
            }
        case .audio(let id):
            if let row, row.kind == .tab(id), audioFrame(row)?.contains(content) == true { model.send(.toggleAudioMute(id)) }
        case .header(let group):
            if row?.kind == .groupHeader(group) { model.send(.toggleGroupCollapsed(group)) }
        case .newTab:
            if row?.kind == .newTab { model.send(.newTab(after: nil, sameKind: event.modifierFlags.contains(.option))) }
        case .tab(let id):
            if let dragged, dragged.isActive {
                endDrag(id, slot: dragged.slot)
            } else if released.collapsesSelection {
                model.clearMultiSelection()
            }
        }
    }

    /// The drop: the strip's intents for the slot (`VerticalTabDrop`).
    func endDrag(_ id: TabID, slot: VerticalTabListLayout.Slot?) {
        guard let slot else { return }
        let drop = VerticalTabDrop(tabs: model.orderedTabs, selection: model.multiSelection, hasGroups: !model.groups.isEmpty)
        if let intent = drop.intent(dropping: id, on: slot) { model.send(intent) }
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        let row = listLayout.row(at: contentPoint(convert(event.locationInWindow, from: nil)))
        press = row.flatMap { Self.tabID($0.kind) }.map { VerticalTabPress(target: .close($0), start: .zero) }
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let row = listLayout.row(at: contentPoint(convert(event.locationInWindow, from: nil)))
        if case .close(let id) = press?.target, let row, Self.tabID(row.kind) == id { model.send(.close(id, source: .middleClick)) }
        press = nil
    }

    // MARK: Menus

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = contextMenu(at: convert(event.locationInWindow, from: nil))
        if let menu { trackMenu(menu) }
        return menu
    }

    /// The right-click target under `point` (view coordinates), the strip's targets.
    func contextTarget(at point: CGPoint) -> TabContextTarget {
        guard let row = listLayout.row(at: contentPoint(point)) else { return .emptyStrip }
        switch row.kind {
        case .tab(let id), .pinned(let id): return .tab(id, selection: model.contextSelection(for: id))
        case .groupHeader(let group): return .group(group)
        case .newTab: return .newTabButton
        case .separator: return .emptyStrip
        }
    }

    func contextMenu(at point: CGPoint) -> NSMenu? {
        contextMenuProvider?(contextTarget(at: point))
    }

    /// A menu from a widened list keeps it wide while open: the pointer leaves the list for it.
    private func trackMenu(_ menu: NSMenu) {
        if let menuEndObserver { NotificationCenter.default.removeObserver(menuEndObserver) }
        menuEndObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                guard let self else { return }
                if let observer = self.menuEndObserver { NotificationCenter.default.removeObserver(observer) }
                self.menuEndObserver = nil
                self.collapseIfPointerLeft()
            }
        }
    }

    // MARK: Scrolling

    public override func scrollWheel(with event: NSEvent) {
        guard maxScrollOffset > 0 else { return super.scrollWheel(with: event) }
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= 12 }
        scrollOffset -= delta
        clampScroll()
        updateAccessibilityRows()
        needsDisplay = true
        updateHover(at: convert(event.locationInWindow, from: nil))
    }
}

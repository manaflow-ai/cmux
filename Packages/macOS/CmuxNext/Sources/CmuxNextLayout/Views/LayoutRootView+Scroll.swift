public import AppKit
import CmuxNextDesign

/// Pointer and trackpad routing. Mouse-downs focus the pane under the pointer. Scrolls follow
/// `layout.scrollModifier` (``LayoutModel/scrollModifier``):
///
/// - `command` (default): a plain scroll, wheel or trackpad, either axis, goes to the pane under
///   the pointer; the layout takes it only over chrome with no pane under it (the gaps between
///   panes and rows, the strip scrollbar). Command + scroll moves the layout anywhere on the
///   screen, a Chromium page's own window included: sideways pans the columns strip (or the
///   innermost scroll area that can move, scroll-areas-DESIGN.md I2), up and down scrolls the rows
///   of the column under the pointer (rows.md V5), or pans the strip over a column whose rows do
///   not overflow. Where the layout has nothing to scroll that way
///   (no strip overflow, no rows that overflow), the pane gets the scroll.
/// - `none`: the rule before `command`. Horizontal gestures over a columns screen are claimed by
///   the layout (first dominant axis decides), except where the pane's own content scrolls
///   sideways (`LayoutRootView+ScrollClaim`); vertical ones pass through, except over a column
///   whose rows overflow: there they scroll the rows over the gaps between rows, or anywhere
///   with Command held.
///
/// Either way the first event of a trackpad gesture (the touch, `mayBegin`, when there is one)
/// decides its owner for the whole gesture, momentum included: pressing or releasing Command
/// midway changes nothing. A mouse wheel
/// decides per notch. A scroll that passes through to a pane focuses it only with
/// focus-follows-mouse on (`LayoutRootView+ScrollFocus`).
extension LayoutRootView {
    enum ScrollLock {
        case idle
        case undecided(ScrollTargets)
        /// A strip pan. `verticalDeltas`: a Command vertical gesture over a column whose rows do not
        /// overflow pans the strip with its vertical deltas (Command + scroll always means the layout).
        case horizontal(ScreenContentView, verticalDeltas: Bool)
        /// A horizontal gesture owned by a scroll area (scroll-areas-DESIGN.md I1, I2).
        case area(ScreenContentView, SplitID)
        case vertical(ScreenContentView, ColumnID)
        case passthrough
        /// A canvas pan (LayoutRootView+Canvas), through its momentum.
        case canvas(ScreenContentView)
        /// A gesture that began over a canvas pane (`none`): horizontal pans, vertical scrolls the pane.
        case canvasUndecided(ScreenContentView)
    }

    func handleMonitored(_ event: NSEvent) -> NSEvent? {
        if event.type == .scrollWheel {
            guard let location = scrollLocationInWindow(of: event) else { return event }
            return handleScroll(event, locationInWindow: location) ? nil : event
        }
        guard event.window === window, window != nil else { return event }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), let active = model.activeScreenID, let view = screenViews[active] else { return event }
            // The strip scrollbar takes its own clicks.
            if let scrollbar = view.scrollbar, !scrollbar.isHidden,
               scrollbar.hitTest(view.convert(event.locationInWindow, from: nil)) != nil { return event }
            if let pane = view.pane(at: view.convert(event.locationInWindow, from: nil)) {
                model.focus(pane, source: .pointer)
            }
            return event
        case .magnify:
            return handleCanvasMagnify(event) ? nil : event
        default:
            return event
        }
    }

    /// Where a monitored scroll event points, in this view's window: its own point when it is
    /// this window's. Under `command`, a Chromium page's own window (a child of this window over
    /// its pane) counts too, so Command + scroll over a page moves the layout and a layout gesture
    /// keeps its events when the strip slides a page under the still pointer. Nil: not ours.
    private func scrollLocationInWindow(of event: NSEvent) -> NSPoint? {
        guard let window, let eventWindow = event.window else { return nil }
        if eventWindow === window { return event.locationInWindow }
        guard eventWindow.parent === window, model.scrollModifier == .command,
              WindowOverlayHost.isPageWindow(eventWindow) else { return nil }
        return window.convertPoint(fromScreen: eventWindow.convertPoint(toScreen: event.locationInWindow))
    }

    /// What the layout could scroll for a gesture or a wheel notch that starts at a point: the
    /// strip (`columns`), a column's rows, the scroll areas there. `columnsTakeEitherAxis`: a
    /// vertical scroll (wheel notch or trackpad gesture) moves the strip when no rows take it (over
    /// the strip scrollbar, or with Command held: a mouse with one wheel still pans the columns).
    struct ScrollTargets {
        var columns: ScreenContentView?
        var rows: (ScreenContentView, ColumnID)?
        var area: (ScreenContentView, NSPoint)?
        var columnsTakeEitherAxis = false

        var isEmpty: Bool { columns == nil && rows == nil && area == nil }
    }

    /// The targets of a scroll starting at `locationInWindow`, by `layout.scrollModifier`.
    private func scrollTargets(_ event: NSEvent, at locationInWindow: NSPoint) -> ScrollTargets {
        switch model.scrollModifier {
        case .noModifier:
            return ScrollTargets(columns: activeColumnsView(at: locationInWindow), rows: rowScrollTarget(event, at: locationInWindow),
                                 area: areaScrollCandidate(at: locationInWindow))
        case .command:
            guard bounds.contains(convert(locationInWindow, from: nil)), let active = model.activeScreenID,
                  let view = screenViews[active] else { return ScrollTargets() }
            let local = view.convert(locationInWindow, from: nil)
            let area = view.areaScrolls.isEmpty ? nil : (view, local)
            if event.modifierFlags.contains(.command) {
                // Anywhere on the screen, over any pane: the layout's scroll.
                return ScrollTargets(columns: view.acceptsHorizontalScroll ? view : nil,
                                     rows: view.rowScrollColumn(at: local, modifierHeld: true).map { (view, $0) }, area: area,
                                     columnsTakeEitherAxis: true)
            }
            if let scrollbar = view.scrollbar, !scrollbar.isHidden, scrollbar.hitTest(local) != nil {
                return ScrollTargets(columns: view.acceptsHorizontalScroll ? view : nil, columnsTakeEitherAxis: true)
            }
            // A plain scroll over a pane is the pane's, whatever its content.
            guard view.pane(at: local) == nil else { return ScrollTargets() }
            return ScrollTargets(columns: view.acceptsHorizontalScroll(at: local) ? view : nil,
                                 rows: view.rowScrollColumn(at: local, modifierHeld: false).map { (view, $0) }, area: area)
        }
    }

    private func activeColumnsView(at locationInWindow: NSPoint) -> ScreenContentView? {
        guard bounds.contains(convert(locationInWindow, from: nil)),
              let active = model.activeScreenID, let view = screenViews[active],
              view.acceptsHorizontalScroll(at: view.convert(locationInWindow, from: nil)),
              !paneContentClaimsHorizontalScroll(at: locationInWindow) else { return nil }
        return view
    }

    /// The active screen and the local point a horizontal scroll here would offer to a scroll
    /// area; nil without areas or where the pane's content scrolls sideways itself (I3).
    private func areaScrollCandidate(at locationInWindow: NSPoint) -> (ScreenContentView, NSPoint)? {
        guard bounds.contains(convert(locationInWindow, from: nil)), let active = model.activeScreenID,
              let view = screenViews[active], !view.areaScrolls.isEmpty,
              !paneContentClaimsHorizontalScroll(at: locationInWindow) else { return nil }
        return (view, view.convert(locationInWindow, from: nil))
    }

    /// The active screen's row column a vertical scroll here would move.
    private func rowScrollTarget(_ event: NSEvent, at locationInWindow: NSPoint) -> (ScreenContentView, ColumnID)? {
        guard bounds.contains(convert(locationInWindow, from: nil)), let active = model.activeScreenID,
              let view = screenViews[active],
              let column = view.rowScrollColumn(at: view.convert(locationInWindow, from: nil),
                                                modifierHeld: event.modifierFlags.contains(.command)) else { return nil }
        return (view, column)
    }

    /// Whether `event` decides its gesture's owner: the touch (`mayBegin`), or `began` when no touch
    /// came first. A `began` after a `mayBegin` keeps the owner the touch chose, so Command pressed
    /// or released between them changes nothing; an end clears the touch.
    private func decidesGestureOwner(_ event: NSEvent) -> Bool {
        let phase = event.phase
        guard event.momentumPhase.isEmpty, !phase.isEmpty else { return false }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            ownerDecidedAtTouch = false
            return false
        }
        if phase.contains(.mayBegin) {
            ownerDecidedAtTouch = true
            return true
        }
        guard phase.contains(.began) else { return false }
        defer { ownerDecidedAtTouch = false }
        return !ownerDecidedAtTouch
    }

    /// Routes one scroll event at `locationInWindow` (the event's own point,
    /// passed apart because a synthesized event can carry no window, and then
    /// its `locationInWindow` is a screen point: `debug.mouse`). Returns true
    /// when the layout consumed it (a strip or row scroll, or momentum the
    /// strip's spring owns).
    public func handleScroll(_ event: NSEvent, locationInWindow: NSPoint) -> Bool {
        handleScrollEvent(event, at: locationInWindow) == nil
    }

    private func handleScrollEvent(_ event: NSEvent, at locationInWindow: NSPoint) -> NSEvent? {
        let decides = decidesGestureOwner(event)
        if let consumed = handleCanvasScroll(event, at: locationInWindow, decides: decides) { return consumed ? nil : event }
        // Momentum after a horizontal gesture we consumed: our spring owns the coast.
        if !event.momentumPhase.isEmpty {
            guard consumeMomentum else { return event }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { consumeMomentum = false }
            return nil
        }

        let phase = event.phase
        if phase.isEmpty {
            // Discrete mouse wheel, decided per notch. Shift+wheel arrives as deltaX.
            let targets = scrollTargets(event, at: locationInWindow)
            let vertical = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
            let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            if vertical, let (view, column) = targets.rows {
                view.discreteRowScroll(column, direction: event.scrollingDeltaY < 0 ? 1 : -1)
                driver.start()
                return nil
            }
            if horizontal, let (view, point) = targets.area {
                let direction = event.scrollingDeltaX < 0 ? 1 : -1
                if let area = view.scrollArea(at: point, direction: direction) {
                    view.discreteAreaScroll(area, direction: direction)
                    driver.start()
                    return nil
                }
            }
            if let view = targets.columns, horizontal || (vertical && targets.columnsTakeEitherAxis) {
                let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
                view.discreteScroll(direction: delta < 0 ? 1 : -1)
                driver.start()
                return nil
            }
            focusPaneForPassThroughScroll(at: locationInWindow)
            return event
        }

        if decides {
            consumeMomentum = false
            let targets = scrollTargets(event, at: locationInWindow)
            scrollLock = targets.isEmpty ? .passthrough : .undecided(targets)
        }

        switch scrollLock {
        case .canvas, .canvasUndecided:
            return event
        case .idle, .passthrough:
            if case .passthrough = scrollLock, phase.contains(.began) { focusPaneForPassThroughScroll(at: locationInWindow) }
            if phase.contains(.ended) || phase.contains(.cancelled) { scrollLock = .idle }
            return event
        case let .undecided(targets):
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            if phase.contains(.ended) || phase.contains(.cancelled) {
                scrollLock = .idle
                return event
            }
            guard dx + dy > 0 else { return event }
            // Innermost first: an area that can move in the gesture's first direction owns it (I2).
            if dx > dy, let (areaView, point) = targets.area,
               let id = areaView.scrollArea(at: point, direction: event.scrollingDeltaX < 0 ? 1 : -1) {
                scrollLock = .area(areaView, id)
                areaView.beginAreaScroll(id)
                areaView.areaScroll(id, deltaX: event.scrollingDeltaX, timestamp: event.timestamp)
                return nil
            }
            if dx > dy, let view = targets.columns {
                scrollLock = .horizontal(view, verticalDeltas: false)
                view.beginUserScroll()
                view.userScroll(deltaX: event.scrollingDeltaX, timestamp: event.timestamp)
                return nil
            }
            if dy >= dx, let (rowsView, column) = targets.rows {
                scrollLock = .vertical(rowsView, column)
                rowsView.beginRowScroll(column)
                rowsView.rowScroll(column, deltaY: event.scrollingDeltaY, timestamp: event.timestamp)
                return nil
            }
            if dy >= dx, targets.columnsTakeEitherAxis, let view = targets.columns {
                scrollLock = .horizontal(view, verticalDeltas: true)
                view.beginUserScroll()
                view.userScroll(deltaX: event.scrollingDeltaY, timestamp: event.timestamp)
                return nil
            }
            scrollLock = .passthrough
            focusPaneForPassThroughScroll(at: locationInWindow)
            return event
        case let .vertical(view, column):
            if phase.contains(.ended) || phase.contains(.cancelled) {
                view.endRowScroll(column, timestamp: event.timestamp)
                scrollLock = .idle
                consumeMomentum = true
                driver.start()
            } else {
                view.rowScroll(column, deltaY: event.scrollingDeltaY, timestamp: event.timestamp)
                updateVisibility()
            }
            return nil
        case let .area(view, id):
            if phase.contains(.ended) || phase.contains(.cancelled) {
                view.endAreaScroll(id, timestamp: event.timestamp)
                scrollLock = .idle
                consumeMomentum = true
                driver.start()
            } else {
                view.areaScroll(id, deltaX: event.scrollingDeltaX, timestamp: event.timestamp)
                updateVisibility()
            }
            return nil
        case let .horizontal(view, verticalDeltas):
            if phase.contains(.ended) || phase.contains(.cancelled) {
                view.endUserScroll(timestamp: event.timestamp)
                scrollLock = .idle
                consumeMomentum = true
                driver.start()
            } else {
                view.userScroll(deltaX: verticalDeltas ? event.scrollingDeltaY : event.scrollingDeltaX, timestamp: event.timestamp)
                updateVisibility()
            }
            return nil
        }
    }
}

import AppKit

/// Pointer and trackpad routing. Mouse-downs focus the pane under the
/// pointer; horizontal scroll gestures over a columns screen are claimed by
/// the layout (first dominant axis decides). Vertical ones pass through,
/// except over a column whose rows overflow: there they scroll the rows
/// over the gaps between rows, or anywhere with Command held (rows.md V5).
extension LayoutRootView {
    enum ScrollLock {
        case idle
        case undecided(ScreenContentView?, rows: (ScreenContentView, ColumnID)?)
        case horizontal(ScreenContentView)
        case vertical(ScreenContentView, ColumnID)
        case passthrough
    }

    func handleMonitored(_ event: NSEvent) -> NSEvent? {
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
        case .scrollWheel:
            return handleScroll(event)
        default:
            return event
        }
    }

    private func activeColumnsView(at locationInWindow: NSPoint) -> ScreenContentView? {
        guard bounds.contains(convert(locationInWindow, from: nil)),
              let active = model.activeScreenID, let view = screenViews[active],
              view.acceptsHorizontalScroll(at: view.convert(locationInWindow, from: nil)) else { return nil }
        return view
    }

    /// The active screen's row column a vertical scroll here would move.
    private func rowScrollTarget(_ event: NSEvent) -> (ScreenContentView, ColumnID)? {
        guard bounds.contains(convert(event.locationInWindow, from: nil)), let active = model.activeScreenID,
              let view = screenViews[active],
              let column = view.rowScrollColumn(at: view.convert(event.locationInWindow, from: nil),
                                                modifierHeld: event.modifierFlags.contains(.command)) else { return nil }
        return (view, column)
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        // Momentum after a horizontal gesture we consumed: our spring owns the coast.
        if !event.momentumPhase.isEmpty {
            guard consumeMomentum else { return event }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { consumeMomentum = false }
            return nil
        }

        let phase = event.phase
        if phase.isEmpty {
            // Discrete mouse wheel. Shift+wheel arrives as deltaX.
            if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let (view, column) = rowScrollTarget(event) {
                view.discreteRowScroll(column, direction: event.scrollingDeltaY < 0 ? 1 : -1)
                driver.start()
                return nil
            }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), let view = activeColumnsView(at: event.locationInWindow) else { return event }
            view.discreteScroll(direction: event.scrollingDeltaX < 0 ? 1 : -1)
            driver.start()
            return nil
        }

        if phase.contains(.mayBegin) || phase.contains(.began) {
            consumeMomentum = false
            let columns = activeColumnsView(at: event.locationInWindow)
            let rows = rowScrollTarget(event)
            scrollLock = columns == nil && rows == nil ? .passthrough : .undecided(columns, rows: rows)
        }

        switch scrollLock {
        case .idle, .passthrough:
            if phase.contains(.ended) || phase.contains(.cancelled) { scrollLock = .idle }
            return event
        case let .undecided(view, rows):
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            if phase.contains(.ended) || phase.contains(.cancelled) {
                scrollLock = .idle
                return event
            }
            guard dx + dy > 0 else { return event }
            if dx > dy, let view {
                scrollLock = .horizontal(view)
                view.beginUserScroll()
                view.userScroll(deltaX: event.scrollingDeltaX, timestamp: event.timestamp)
                return nil
            }
            if dy >= dx, let (rowsView, column) = rows {
                scrollLock = .vertical(rowsView, column)
                rowsView.beginRowScroll(column)
                rowsView.rowScroll(column, deltaY: event.scrollingDeltaY, timestamp: event.timestamp)
                return nil
            }
            scrollLock = .passthrough
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
        case let .horizontal(view):
            if phase.contains(.ended) || phase.contains(.cancelled) {
                view.endUserScroll(timestamp: event.timestamp)
                scrollLock = .idle
                consumeMomentum = true
                driver.start()
            } else {
                view.userScroll(deltaX: event.scrollingDeltaX, timestamp: event.timestamp)
                updateVisibility()
            }
            return nil
        }
    }
}

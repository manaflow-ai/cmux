import AppKit

/// Pointer and trackpad routing. Mouse-downs focus the pane under the
/// pointer; horizontal scroll gestures over a columns screen are claimed by
/// the layout (first dominant axis decides), vertical ones pass through.
extension LayoutRootView {
    enum ScrollLock {
        case idle
        case undecided(ScreenContentView)
        case horizontal(ScreenContentView)
        case passthrough
    }

    func handleMonitored(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window != nil else { return event }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point), let active = model.activeScreenID, let view = screenViews[active] else { return event }
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
              let active = model.activeScreenID, let view = screenViews[active], view.acceptsHorizontalScroll else { return nil }
        return view
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
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY), let view = activeColumnsView(at: event.locationInWindow) else { return event }
            view.discreteScroll(direction: event.scrollingDeltaX < 0 ? 1 : -1)
            driver.start()
            return nil
        }

        if phase.contains(.mayBegin) || phase.contains(.began) {
            consumeMomentum = false
            if let view = activeColumnsView(at: event.locationInWindow) {
                scrollLock = .undecided(view)
            } else {
                scrollLock = .passthrough
            }
        }

        switch scrollLock {
        case .idle, .passthrough:
            if phase.contains(.ended) || phase.contains(.cancelled) { scrollLock = .idle }
            return event
        case let .undecided(view):
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            if phase.contains(.ended) || phase.contains(.cancelled) {
                scrollLock = .idle
                return event
            }
            guard dx + dy > 0 else { return event }
            if dx > dy {
                scrollLock = .horizontal(view)
                view.beginUserScroll()
                view.userScroll(deltaX: event.scrollingDeltaX, timestamp: event.timestamp)
                return nil
            }
            scrollLock = .passthrough
            return event
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

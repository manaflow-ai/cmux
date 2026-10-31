public import AppKit
public import CmuxNextDesign
import CmuxNextInput

/// Pointer and trackpad routing. Mouse-downs focus the pane under the pointer. Scrolls follow
/// `layout.scrollModifier` (``LayoutModel/scrollModifier``):
///
/// - `command` (default): a plain scroll, wheel or trackpad, either axis, goes to the pane under
///   the pointer; the layout takes it only over chrome with no pane under it (the gaps between
///   panes and rows, the strip scrollbar, the divider catcher panels over Chromium pages). Command
///   + scroll moves the layout anywhere on the screen, a Chromium page's own window included:
///   sideways pans the columns strip (or the innermost scroll area under the pointer that can move,
///   scroll-areas-DESIGN.md I2), up and down scrolls the rows of the column under the pointer
///   (rows.md V5), or pans the strip over a column whose rows do not overflow. A Command gesture
///   that starts where the layout has anything to scroll (strip overflow, rows that overflow under
///   the pointer, a scroll area under the pointer that can move) is the layout's even when its
///   direction has nothing to move: it is kept and nothing moves. Only where the layout has
///   nothing at all to scroll does the pane get the Command gesture.
/// - `none`: the rule before `command`. Horizontal gestures over a columns screen are claimed by
///   the layout (first dominant axis decides), except where the pane's own content scrolls
///   sideways (`LayoutRootView+ScrollClaim`); vertical ones pass through, except over a column
///   whose rows overflow: there they scroll the rows over the gaps between rows, or anywhere
///   with Command held. A gesture that starts in a Chromium page's window is the page's.
///
/// Either way the first event of a trackpad gesture (the touch, `mayBegin`, when there is one)
/// decides its owner for the whole gesture, momentum included: pressing or releasing Command
/// midway changes nothing. Under `command`, a gesture that begins with Command held where the
/// layout has anything to scroll is the layout's from that first event: the pane under the
/// pointer never sees any of it, not even its zero-delta start, and the direction of the first
/// move picks what moves. That decision is the only one: content that reacts to the same gesture
/// itself (a Chromium page's swipe Back or Forward) reads it through ``ScrollGestureOwning``.
/// Under both modifiers the layout sees the events of its page windows: a gesture it took keeps
/// its events, end and coast included, when a pan slides a page under the still pointer, and a
/// gesture that starts in a page window replaces the last gesture's lock.
/// A mouse wheel decides per notch. A scroll that passes through to a pane focuses it only with
/// focus-follows-mouse on (`LayoutRootView+ScrollFocus`).
extension LayoutRootView: ScrollGestureOwning {
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
        /// A canvas pan (LayoutRootView+Canvas), until the gesture ends.
        case canvas(ScreenContentView)
        /// The momentum that may follow a canvas pan, which the canvas owns. The gesture is over
        /// (the layout owns no gesture now); the next gesture replaces it.
        case canvasCoast(ScreenContentView)
        /// A gesture that began over a canvas pane (`none`): horizontal pans, vertical scrolls the pane.
        case canvasUndecided(ScreenContentView)
        /// A gesture the layout took at its first event (``ScrollTargets/claimsWholeGesture``) that
        /// has nothing to move its way: the layout keeps its events, so the pane, which never saw
        /// the gesture start, sees none of it, and nothing moves.
        case claimed
    }

    /// Whether the layout took the current trackpad gesture (``ScrollGestureOwning``): a strip,
    /// row, area or canvas scroll, or a Command gesture claimed at its first event. False once that
    /// gesture's end came: its coast belongs to the layout, but no gesture is current.
    public var ownsCurrentScrollGesture: Bool {
        switch scrollLock {
        case .horizontal, .area, .vertical, .canvas, .claimed: true
        case let .undecided(targets): targets.claimsWholeGesture
        case .idle, .passthrough, .canvasUndecided, .canvasCoast: false
        }
    }

    /// The root's intercept on the app's input tap while it is live: scrolls, magnify and button presses,
    /// at ``InputEventTap/InterceptOrder/layout`` (after a modal overlay, a popup and a drag session).
    /// It hears every window: the root's own divider catcher panels are panels, which a window scope leaves
    /// out, and ``scrollOrigin(of:at:in:)`` and the button routing drop another window's event in O(1).
    /// Chrome routes a wheel event to the widget under the pointer the same way, before the page sees it
    /// (content/browser/renderer_host/render_widget_host_input_event_router.cc, RouteMouseWheelEvent).
    func subscribeInput() -> InputSubscription? {
        inputTap?.subscribe(class: [.scroll, .gesture, .button], phase: .intercept(order: .layout)) { [weak self] event in
            guard let self else { return .pass }
            return handleMonitored(event) == nil ? .consume : .pass
        }
    }

    /// The tap intercept's routing of one event: nil when the layout consumed it.
    func handleMonitored(_ event: NSEvent) -> NSEvent? {
        if event.type == .scrollWheel { return handleMonitoredScroll(event, from: event.window, at: event.locationInWindow) }
        guard event.window === window, window != nil else { return event }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handleMonitoredPress(at: event.locationInWindow)
            return event
        case .magnify:
            return handleCanvasMagnify(event) ? nil : event
        default:
            return event
        }
    }

    /// A press at `locationInWindow` (the window's coordinates), as the intercept sees it before AppKit
    /// dispatches it: the pane under it takes the focus. Apart from ``handleMonitored(_:)`` so tests can
    /// send a press, which a synthesized event for a window off screen cannot carry.
    func handleMonitoredPress(at locationInWindow: NSPoint) {
        // AppKit hit tests the press on the frames: a strip that shows moved lands where it shows first.
        landStripsWhereTheyShow()
        let point = convert(locationInWindow, from: nil)
        guard bounds.contains(point), let active = model.activeScreenID, let view = screenViews[active] else { return }
        // The strip scrollbar takes its own clicks.
        if let scrollbar = view.scrollbar, !scrollbar.isHidden,
           scrollbar.hitTest(view.convert(locationInWindow, from: nil)) != nil { return }
        // Mid render-server spring, the pane drawn under the press, as AppKit's hit test. Only the pane AppKit
        // gives the press to takes the focus (cmux-ad P0 2026-10-31): a press the window frame keeps (a resize
        // at an edge or corner, inside the frame too), a divider's hit area, the sidebar's resize band or the
        // titlebar's buttons reaches no pane, although it lies over one, so the focus stays where the person typed.
        // Both must name the same pane. Mid render-server spring the pane drawn under the press and the model's
        // pane there can differ: `pressedPane` reads the drawn layers, and the frame view's hit test reaches the
        // drawn view only through `ScreenContentView.hitTest`. A press that the two answers do not agree on
        // focuses nothing, so a spring never moves the keys to a pane the press did not reach.
        if let pane = view.pressedPane(at: view.convert(locationInWindow, from: nil)),
           paneReceivingPress(at: locationInWindow, in: view) == pane {
            model.focus(pane, source: .pointer)
        }
    }

    /// The pane a press at `locationInWindow` reaches: the one whose host holds the view AppKit
    /// dispatches the press to, by its hit test from the window's frame view (mid render-server spring
    /// ``ScreenContentView`` answers it where the views are drawn). Nil when the press reaches no pane of
    /// `screen` (the frame view, a divider, a view over the layout such as the sidebar's resize band).
    func paneReceivingPress(at locationInWindow: NSPoint, in screen: ScreenContentView) -> PaneID? {
        guard let frameView = window?.contentView?.superview,
              let hit = frameView.hitTest(frameView.convert(locationInWindow, from: nil)) else { return nil }
        for view in sequence(first: hit, next: \.superview) {
            if view === screen { return nil }
            if let host = view as? PaneHostView, context.hosts[host.pane] === host, host.isDescendant(of: screen) { return host.pane }
        }
        return nil
    }

    /// The intercept's scroll routing: `event` as `eventWindow`, the window AppKit sent it to, has it
    /// at `location` (that window's coordinates). Apart from ``handleMonitored(_:)`` so tests can
    /// send an event from a page or catcher window, which a synthesized event cannot carry.
    /// Returns the event when it goes on, nil when the layout consumed it.
    ///
    /// The entry point for synthetic scrolls (`debug.mouse`, benches): it must stay behavior-equal to the
    /// intercept path, which calls it for every real scroll.
    public func handleMonitoredScroll(_ event: NSEvent, from eventWindow: NSWindow?, at location: NSPoint) -> NSEvent? {
        if passesWithoutRouting(event, from: eventWindow) { return event }
        guard let origin = scrollOrigin(of: eventWindow, at: location) else { return event }
        return handleScrollEvent(event, at: origin.locationInWindow, fromPageWindow: origin.isPageWindow)
    }

    /// What the layout could scroll for a gesture or a wheel notch that starts at a point: the
    /// strip (`columns`), a column's rows, the scroll areas there. `columnsTakeEitherAxis`: a
    /// vertical scroll (wheel notch or trackpad gesture) moves the strip when no rows take it (over
    /// the strip scrollbar, or with Command held: a mouse with one wheel still pans the columns).
    /// `claimsWholeGesture`: a Command gesture under `command` with any target is the layout's from
    /// its first event, whatever way it then moves (the pane never sees its start).
    struct ScrollTargets {
        var columns: ScreenContentView?
        var rows: (ScreenContentView, ColumnID)?
        var area: (ScreenContentView, NSPoint)?
        var columnsTakeEitherAxis = false
        var claimsWholeGesture = false

        var isEmpty: Bool { columns == nil && rows == nil && area == nil }
    }

    /// The targets of a scroll starting at `locationInWindow`, by `layout.scrollModifier`.
    /// `fromPageWindow`: the event came from a page window (``scrollOrigin(of:at:in:)``); there
    /// only Command + scroll under `command` is the layout's, any other scroll is the page's
    /// wherever it is.
    private func scrollTargets(_ event: NSEvent, at locationInWindow: NSPoint, fromPageWindow: Bool) -> ScrollTargets {
        switch model.scrollModifier {
        case .noModifier:
            guard !fromPageWindow else { return ScrollTargets() }
            return ScrollTargets(columns: activeColumnsView(at: locationInWindow), rows: rowScrollTarget(event, at: locationInWindow),
                                 area: areaScrollCandidate(at: locationInWindow))
        case .command:
            guard bounds.contains(convert(locationInWindow, from: nil)), let active = model.activeScreenID,
                  let view = screenViews[active] else { return ScrollTargets() }
            let local = view.convert(locationInWindow, from: nil)
            // Only an area under the pointer that can move counts (one elsewhere must not claim a Command
            // gesture with nothing to scroll here); asked after a plain scroll's pane test.
            func movableArea() -> (ScreenContentView, NSPoint)? {
                view.scrollArea(at: local, direction: 1) != nil || view.scrollArea(at: local, direction: -1) != nil ? (view, local) : nil
            }
            if event.modifierFlags.contains(.command) {
                // Anywhere on the screen, over any pane: the layout's scroll.
                var targets = ScrollTargets(columns: view.acceptsHorizontalScroll ? view : nil,
                                            rows: view.rowScrollColumn(at: local, modifierHeld: true).map { (view, $0) },
                                            area: movableArea(), columnsTakeEitherAxis: true)
                targets.claimsWholeGesture = !targets.isEmpty
                return targets
            }
            guard !fromPageWindow else { return ScrollTargets() }
            if let scrollbar = view.scrollbar, !scrollbar.isHidden, scrollbar.hitTest(local) != nil {
                return ScrollTargets(columns: view.acceptsHorizontalScroll ? view : nil, columnsTakeEitherAxis: true)
            }
            // A plain scroll over a pane is the pane's, whatever its content.
            guard view.pane(at: local) == nil else { return ScrollTargets() }
            return ScrollTargets(columns: view.acceptsHorizontalScroll(at: local) ? view : nil,
                                 rows: view.rowScrollColumn(at: local, modifierHeld: false).map { (view, $0) }, area: movableArea())
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
    ///
    /// A touch outside this view decides (nothing: the gesture is not this layout's) but is not
    /// remembered. Several layouts share a window (multi-view) and each sees the touch, but only
    /// the one under the pointer sees the rest of a gesture it takes; a remembered touch in another
    /// one would outlive its gesture and stop that layout's next gesture without a touch (a Magic
    /// Mouse, a re-swipe during momentum) from deciding.
    private func decidesGestureOwner(_ event: NSEvent, at locationInWindow: NSPoint) -> Bool {
        let phase = event.phase
        guard event.momentumPhase.isEmpty, !phase.isEmpty else { return false }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            ownerDecidedAtTouch = false
            return false
        }
        if phase.contains(.mayBegin) {
            ownerDecidedAtTouch = bounds.contains(convert(locationInWindow, from: nil))
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
        handleScrollEvent(event, at: locationInWindow, fromPageWindow: false) == nil
    }

    /// ``handleScroll(_:locationInWindow:)`` for the event monitor; returns the event when it goes
    /// on, nil when consumed. `fromPageWindow`: the event came from a page window over a pane
    /// (``scrollOrigin(of:at:in:)``). A consumed event is reported once (``onScrollTaken``).
    func handleScrollEvent(_ event: NSEvent, at locationInWindow: NSPoint, fromPageWindow: Bool) -> NSEvent? {
        context.routedScrolls &+= 1
        let routed = routeScrollEvent(event, at: locationInWindow, fromPageWindow: fromPageWindow)
        if routed == nil { onScrollTaken?() }
        return routed
    }

    /// The routing of ``handleScrollEvent(_:at:fromPageWindow:)``: the event when it goes on, nil when the
    /// layout consumed it.
    private func routeScrollEvent(_ event: NSEvent, at locationInWindow: NSPoint, fromPageWindow: Bool) -> NSEvent? {
        let decides = decidesGestureOwner(event, at: locationInWindow)
        // A new gesture or wheel notch is targeted on the frames: a strip that shows moved lands first.
        if decides || (event.phase.isEmpty && event.momentumPhase.isEmpty) { landStripsWhereTheyShow() }
        if let consumed = handleCanvasScroll(event, at: locationInWindow, decides: decides, fromPageWindow: fromPageWindow) {
            return consumed ? nil : event
        }
        // Momentum after a horizontal gesture we consumed: our spring owns the coast.
        if !event.momentumPhase.isEmpty {
            guard consumeMomentum else { return event }
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { consumeMomentum = false }
            return nil
        }

        let phase = event.phase
        if phase.isEmpty {
            // Discrete mouse wheel, decided per notch. Shift+wheel arrives as deltaX.
            let targets = scrollTargets(event, at: locationInWindow, fromPageWindow: fromPageWindow)
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
            let targets = scrollTargets(event, at: locationInWindow, fromPageWindow: fromPageWindow)
            scrollLock = targets.isEmpty ? .passthrough : .undecided(targets)
        }

        switch scrollLock {
        case .canvas, .canvasUndecided, .canvasCoast:
            return event
        case .claimed:
            if phase.contains(.ended) || phase.contains(.cancelled) {
                scrollLock = .idle
                consumeMomentum = true
            }
            return nil
        case .idle, .passthrough:
            if case .passthrough = scrollLock, phase.contains(.began) { focusPaneForPassThroughScroll(at: locationInWindow) }
            if phase.contains(.ended) || phase.contains(.cancelled) { scrollLock = .idle }
            return event
        case let .undecided(targets):
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            // A claimed gesture's start (the touch, a `began` with no delta) and an end before it
            // moved stay the layout's: the pane must never see a gesture start that does not end.
            let unmoved: NSEvent? = targets.claimsWholeGesture ? nil : event
            if phase.contains(.ended) || phase.contains(.cancelled) {
                scrollLock = .idle
                if targets.claimsWholeGesture { consumeMomentum = true }
                return unmoved
            }
            guard dx + dy > 0 else { return unmoved }
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
                view.beginUserScroll(trackpad: true)
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
                view.beginUserScroll(trackpad: true)
                view.userScroll(deltaX: event.scrollingDeltaY, timestamp: event.timestamp)
                return nil
            }
            if targets.claimsWholeGesture {
                scrollLock = .claimed
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
                // Only a pan that brings a pane in or out of the viewport or its keep-alive band reports.
                if !view.panKeepsVisibility { updateVisibility() }
            }
            return nil
        }
    }
}

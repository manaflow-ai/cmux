public import AppKit

extension WindowOverlayHost {
    // MARK: Mouse

    /// The panel takes the mouse only where an interactive overlay is. The
    /// window server picks a window before any app code sees a click, so the
    /// panel switches on mouse moves (and on every present, layout and
    /// dismiss) for the point under the pointer.
    func updateMouseRouting() {
        if isAppHost {
            panel.ignoresMouseEvents = handles.isEmpty
            return
        }
        let regions = interactiveRegions()
        guard !regions.isEmpty || showsAgentCursorTags else {
            panel.ignoresMouseEvents = true
            removeMouseMonitor()
            return
        }
        routeMouse(at: NSEvent.mouseLocation)
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                                                   .otherMouseDragged, .mouseEntered, .mouseExited,
                                                                   .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                                   .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            // A press or a scroll on an overlay that the window server gave to a window under the panel (a page
            // window, the window itself) goes to the panel; nothing under the overlay gets it.
            if self.takeEventFromBelow(event) { return nil }
            if [.leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel].contains(event.type) { return event }
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
                self.clickDidLand(in: event.window, at: event.window === self.panel ? event.locationInWindow : .zero)
            } else {
                self.routeMouse(at: NSEvent.mouseLocation)
            }
            return event
        }
    }

    func routeMouse(at screenPoint: NSPoint) {
        let point = panel.frame.isEmpty ? screenPoint : panel.convertPoint(fromScreen: screenPoint)
        let accepts = acceptsMouse(at: point)
        if panel.ignoresMouseEvents == accepts {
            panel.ignoresMouseEvents = !accepts
            // The pointer came onto an overlay: a cursor that the window under it set (a divider's resize cursor, a
            // terminal's I-beam) does not stay on the overlay.
            if accepts { NSCursor.arrow.set() }
        }
        hoverAgentCursorTag(at: point)
    }

    /// Takes a press, its drags and release, or a scroll that reached a window under the panel (the panel's window
    /// or one of its child windows: a page, a divider catcher) at a point where an overlay takes the mouse, and gives
    /// it to the panel. Returns true when it took the event: the window it reached must not handle it.
    ///
    /// The panel takes the mouse only after a move the app sees switched it on (``routeMouse(at:)``). With the window
    /// in the background (it gets no moves) or a pointer that did not move since the overlay came, the window server
    /// gives a press or a scroll on the overlay to the window under it: a right-click on a toast opened the terminal
    /// pane's menu or the divider's, and a scroll on it scrolled the terminal (cmux-lawrence-2, 2026-11-16). The host's
    /// mouse monitor asks this for every window of the app; the window asks it in `sendEvent` too, for the events a
    /// divider catcher forwards (those pass no monitor).
    ///
    /// - Parameter event: A mouse or scroll event on its way to a window that is not the panel.
    /// - Returns: True when the panel got the event instead.
    public func takeEventFromBelow(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            break
        default:
            return false
        }
        guard !isAppHost, let window, let source = event.window, source !== panel, source === window || source.parent === window,
              panel.parent === window, panel.isVisible else { return false }
        let screen = source.convertPoint(toScreen: event.locationInWindow)
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            guard acceptsMouse(at: panel.convertPoint(fromScreen: screen)) else {
                // A press elsewhere: a taken press whose release never came (a menu loop took it) is over.
                if event.type != .scrollWheel { takenButton = nil }
                return false
            }
            panel.ignoresMouseEvents = false
            if event.type != .scrollWheel { takenButton = Self.button(of: event) }
        default:
            guard let takenButton, Self.button(of: event) == takenButton else { return false }
            if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(event.type) { self.takenButton = nil }
        }
        clickTrace.overlayTook(event, from: source, panel: panel)
        deliver(event, to: panel, screen: screen)
        return true
    }

    /// ``takeEventFromBelow(_:)`` for the overlay host of `window`, asked by the window's `sendEvent` for every event:
    /// any event that is not a press, a drag, a release or a scroll returns false before the host is looked up.
    ///
    /// - Parameters:
    ///   - event: The event `window` is about to handle.
    ///   - window: The window with the overlays.
    /// - Returns: True when the overlay panel got the event instead: `window` must not handle it.
    public static func takeEventFromBelow(_ event: NSEvent, in window: NSWindow) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .leftMouseDragged, .rightMouseDragged,
             .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return existingHost(for: window)?.takeEventFromBelow(event) ?? false
        default:
            return false
        }
    }

    /// Whether an overlay of `window` takes the mouse at `windowPoint` (a toast, a dialog, an agent's cursor tag).
    ///
    /// The overlay panel is above everything of the window there, so nothing of the window may follow the pointer
    /// at that point: no hover, no cursor, no moves. The window server gives the panel the pointer only after its
    /// mouse routing switched it on, one move late, and a window's own tracking reads where the pointer is, not
    /// which window has it: each pointer follower of the window asks this.
    ///
    /// - Parameters:
    ///   - window: The window whose overlays are asked.
    ///   - windowPoint: A point in `window`'s coordinates.
    /// - Returns: True when an overlay of the window shows and takes the mouse at the point.
    public static func overlayTakesMouse(in window: NSWindow, atWindowPoint windowPoint: NSPoint) -> Bool {
        guard let host = existingHost(for: window), !host.isAppHost, host.panel.parent === window, host.panel.isVisible
        else { return false }
        return host.acceptsMouse(at: host.panel.convertPoint(fromScreen: window.convertPoint(toScreen: windowPoint)))
    }

    /// A tab dialog takes the keyboard when a click lands on it; a click
    /// anywhere else leaves the keyboard where that click puts it.
    func wantsKey(forClickIn clicked: NSWindow?, at point: NSPoint) -> Bool {
        guard clicked === panel else { return false }
        let bounds = panel.overlayContainer.bounds
        return handles.contains { $0.options.isModal && ($0.options.modalRegion ?? bounds).contains(point) }
    }

    func clickDidLand(in clicked: NSWindow?, at point: NSPoint) {
        guard wantsKey(forClickIn: clicked, at: point), !panel.isKeyWindow else { return }
        panel.makeKey()
        if let top = handles.last(where: { $0.options.isModal }), !(panel.firstResponder is NSText) {
            panel.makeFirstResponder(Self.keyViews(in: top.content).first ?? top.content)
        }
    }

    /// A mouse event reached the panel. A move updates the routing; a click
    /// outside every interactive region (the panel had not let go yet) goes
    /// on to the parent window, and the panel lets go of the mouse.
    func panelMouseEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A new click: an earlier forwarded click whose up never reached
            // the panel (a drag session or a menu loop took it) is over.
            forwardTarget = nil
            let point = event.locationInWindow
            guard !isAppHost, !acceptsMouse(at: point), let window else { return false }
            panel.ignoresMouseEvents = true
            // The rest of this click (drags and the up of the same button)
            // still comes to the panel, which got the down: it goes to the same target.
            forwardTarget = forwardingTarget(for: panel.convertPoint(toScreen: point), in: window)
            forwardButton = Self.button(of: event)
            if let forwardTarget { clickTrace.forwarded(event, to: forwardTarget) }
            forward(event)
            return true
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard forwardTarget != nil, Self.button(of: event) == forwardButton else {
                if forwardTarget == nil { routeMouse(at: NSEvent.mouseLocation) }
                return false
            }
            forward(event)
            return true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard forwardTarget != nil, Self.button(of: event) == forwardButton else { return false }
            forward(event)
            forwardTarget = nil
            return true
        case .mouseMoved, .mouseEntered, .mouseExited:
            routeMouse(at: NSEvent.mouseLocation)
            return false
        default:
            return false
        }
    }

    /// The mouse button of an event: from its type for left and right
    /// (`buttonNumber` is not set on every event), else `buttonNumber`.
    static func button(of event: NSEvent) -> Int {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: 0
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: 1
        default: max(2, event.buttonNumber)
        }
    }

    /// The window under a click outside every interactive region: the
    /// window itself over an occluder (the sidebar, where page frames run
    /// under it), else the frontmost page window there, else the window.
    func forwardingTarget(for screenPoint: NSPoint, in window: NSWindow) -> NSWindow {
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        if occluderRects.contains(where: { $0.contains(windowPoint) }) { return window }
        return Self.frontPageWindow(at: screenPoint, in: window) ?? window
    }

    /// The frontmost visible page window (``isPageWindow(_:)``) of `window` under `screenPoint`, as the window
    /// server picks the window a pointer event goes to; nil over no page.
    ///
    /// - Parameters:
    ///   - screenPoint: A point in screen coordinates.
    ///   - window: The window whose child page windows are searched.
    /// - Returns: The page window under the point, or nil.
    public static func frontPageWindow(at screenPoint: NSPoint, in window: NSWindow) -> NSWindow? {
        let pages = (window.childWindows ?? []).filter { isPageWindow($0) && $0.isVisible && $0.frame.contains(screenPoint) }
        guard pages.count > 1 else { return pages.first }
        // Front to back (child order is add order, not z-order).
        let order = (NSWindow.windowNumbers(options: []) ?? []).map(\.intValue)
        return pages.min { (order.firstIndex(of: $0.windowNumber) ?? .max) < (order.firstIndex(of: $1.windowNumber) ?? .max) }
    }

    /// Sends `event` to `forwardTarget` in that window's coordinates. It runs
    /// inside the panel's sendEvent, so NSApp.currentEvent is still the
    /// panel's event and local monitors do not see the forwarded copy.
    func forward(_ event: NSEvent) {
        guard let target = forwardTarget else { return }
        deliver(event, to: target, screen: panel.convertPoint(toScreen: event.locationInWindow))
    }

    /// Sends `event` to `target` at `screen` (a screen point), as the window server would have.
    func deliver(_ event: NSEvent, to target: NSWindow, screen: NSPoint) {
        // A copy of the real event keeps its drag deltas (pointer lock, page
        // drags use them); only the window and location change.
        if let copy = event.cgEvent?.copy() {
            copy.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowNumber))
            copy.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowNumber))
            if let forwarded = NSEvent(cgEvent: copy) {
                let addressed = Self.relocated(forwarded, to: target, screen: screen)
                // A scroll the copy did not address to `target` goes nowhere rather than to the wrong window.
                if addressed == nil, forwarded.type == .scrollWheel { return }
                return target.sendEvent(addressed ?? forwarded)
            }
        }
        if let forwarded = Self.relocated(event, to: target, screen: screen) { target.sendEvent(forwarded) }
    }

    /// `event` addressed to `target` at the screen point (deltas are lost: a fallback only). Nil for a scroll, which
    /// has no such constructor: its copy above is the only way, and with no copy the scroll goes nowhere.
    static func relocated(_ event: NSEvent, to target: NSWindow, screen: NSPoint) -> NSEvent? {
        guard event.window !== target else { return event }
        guard event.type != .scrollWheel else { return nil }
        return NSEvent.mouseEvent(with: event.type, location: target.convertPoint(fromScreen: screen),
                                  modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                  windowNumber: target.windowNumber, context: nil, eventNumber: event.eventNumber,
                                  clickCount: event.clickCount, pressure: event.pressure)
    }

    func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }
}

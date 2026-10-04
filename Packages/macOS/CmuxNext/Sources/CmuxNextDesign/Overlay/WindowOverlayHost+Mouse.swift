import AppKit

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
        guard !regions.isEmpty else {
            panel.ignoresMouseEvents = true
            removeMouseMonitor()
            return
        }
        routeMouse(at: NSEvent.mouseLocation)
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                                                   .otherMouseDragged, .mouseEntered, .mouseExited,
                                                                   .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
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
        if panel.ignoresMouseEvents == accepts { panel.ignoresMouseEvents = !accepts }
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
            forwardButton = event.buttonNumber
            forward(event)
            return true
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard forwardTarget != nil, event.buttonNumber == forwardButton else {
                if forwardTarget == nil { routeMouse(at: NSEvent.mouseLocation) }
                return false
            }
            forward(event)
            return true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard forwardTarget != nil, event.buttonNumber == forwardButton else { return false }
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

    /// The window under a click outside every interactive region: the
    /// window itself over an occluder (the sidebar, where page frames run
    /// under it), else the frontmost page window there, else the window.
    func forwardingTarget(for screenPoint: NSPoint, in window: NSWindow) -> NSWindow {
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        if occluderRects.contains(where: { $0.contains(windowPoint) }) { return window }
        let pages = (window.childWindows ?? []).filter { Self.isPageWindow($0) && $0.isVisible && $0.frame.contains(screenPoint) }
        guard pages.count > 1 else { return pages.first ?? window }
        // Front to back (child order is add order, not z-order).
        let order = NSWindow.windowNumbers(options: []) ?? []
        return pages.min { (order.firstIndex(of: $0.windowNumber) ?? .max) < (order.firstIndex(of: $1.windowNumber) ?? .max) } ?? window
    }

    /// Sends `event` to `forwardTarget` in that window's coordinates. It runs
    /// inside the panel's sendEvent, so NSApp.currentEvent is still the
    /// panel's event and local monitors do not see the forwarded copy.
    func forward(_ event: NSEvent) {
        guard let target = forwardTarget else { return }
        let screen = panel.convertPoint(toScreen: event.locationInWindow)
        // A copy of the real event keeps its drag deltas (pointer lock, page
        // drags use them); only the window and location change.
        if let copy = event.cgEvent?.copy() {
            copy.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowNumber))
            copy.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowNumber))
            if let forwarded = NSEvent(cgEvent: copy) {
                return target.sendEvent(Self.relocated(forwarded, to: target, screen: screen) ?? forwarded)
            }
        }
        if let forwarded = Self.relocated(event, to: target, screen: screen) { target.sendEvent(forwarded) }
    }

    /// `event` addressed to `target` at the screen point (deltas are lost: a fallback only).
    static func relocated(_ event: NSEvent, to target: NSWindow, screen: NSPoint) -> NSEvent? {
        guard event.window !== target else { return event }
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

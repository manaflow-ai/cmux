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
        case .mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged, .rightMouseDragged:
            routeMouse(at: NSEvent.mouseLocation)
            return false
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let point = event.locationInWindow
            guard !isAppHost, !acceptsMouse(at: point), let window else { return false }
            panel.ignoresMouseEvents = true
            // The window under the click: a page window there, else the parent.
            let screen = panel.convertPoint(toScreen: point)
            let target = (window.childWindows ?? []).reversed().first {
                Self.isPageWindow($0) && $0.isVisible && $0.frame.contains(screen)
            } ?? window
            if let forwarded = NSEvent.mouseEvent(with: event.type, location: target.convertPoint(fromScreen: screen),
                                                  modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                                  windowNumber: target.windowNumber, context: nil, eventNumber: event.eventNumber,
                                                  clickCount: event.clickCount, pressure: event.pressure) {
                target.sendEvent(forwarded)
            }
            return true
        default:
            return false
        }
    }

    func removeMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }
}

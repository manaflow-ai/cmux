import AppKit

final class WindowDecorationsController {
    private var observers: [NSObjectProtocol] = []
    private var didStart = false
    private var trafficLightBaseFrames: [ObjectIdentifier: [NSWindow.ButtonType: NSRect]] = [:]
    private var minimalModeTitlebarDoubleClickMonitor: Any?
    private var minimalModeSidebarChromeHoverMonitor: Any?
    private var lastMinimalModeTitlebarClick: MinimalModeTitlebarClickRecord?

    deinit {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        if let minimalModeTitlebarDoubleClickMonitor {
            NSEvent.removeMonitor(minimalModeTitlebarDoubleClickMonitor)
        }
        if let minimalModeSidebarChromeHoverMonitor {
            NSEvent.removeMonitor(minimalModeSidebarChromeHoverMonitor)
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        attachToExistingWindows()
        installObservers()
        installMinimalModeTitlebarDoubleClickMonitor()
        installMinimalModeSidebarChromeHoverMonitor()
    }

    func apply(to window: NSWindow) {
        let shouldHideButtons = shouldHideTrafficLights(for: window)
        hideStandardButtons(on: window, hidden: shouldHideButtons)
        applyTrafficLightOffset(on: window, hidden: shouldHideButtons)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            self.apply(to: window)
        }
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main, using: handler))
        observers.append(center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main, using: handler))
    }

    private func installMinimalModeTitlebarDoubleClickMonitor() {
        guard minimalModeTitlebarDoubleClickMonitor == nil else { return }
        minimalModeTitlebarDoubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, let window = event.window else { return event }
            guard isMinimalModeWindowTitlebarClickCandidate(window: window, event: event) else {
                self.lastMinimalModeTitlebarClick = nil
                return event
            }
            guard !isMinimalModeTitlebarControlHit(window: window, locationInWindow: event.locationInWindow) else {
                self.lastMinimalModeTitlebarClick = nil
                return event
            }

            let windowNumber = window.windowNumber
            let isDoubleClick = minimalModeTitlebarClickFormsDoubleClick(
                clickCount: event.clickCount,
                timestamp: event.timestamp,
                locationInWindow: event.locationInWindow,
                windowNumber: windowNumber,
                previous: self.lastMinimalModeTitlebarClick,
                doubleClickInterval: NSEvent.doubleClickInterval
            )

            guard isDoubleClick else {
                self.lastMinimalModeTitlebarClick = MinimalModeTitlebarClickRecord(
                    windowNumber: windowNumber,
                    timestamp: event.timestamp,
                    locationInWindow: event.locationInWindow
                )
                return event
            }

            self.lastMinimalModeTitlebarClick = nil
            let result = handleTitlebarDoubleClick(window: window, behavior: .standardAction)
#if DEBUG
            cmuxDebugLog(
                "titlebar.minimalWindowDoubleClick.result=\(String(describing: result)) point=\(NSStringFromPoint(event.locationInWindow)) band=\(String(format: "%.1f", minimalModeTitlebarDoubleClickBandHeight(for: window)))"
            )
#endif
            return result.consumesEvent ? nil : event
        }
    }

    private func installMinimalModeSidebarChromeHoverMonitor() {
        guard minimalModeSidebarChromeHoverMonitor == nil else { return }
        minimalModeSidebarChromeHoverMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseDragged]
        ) { event in
            guard let window = event.window else {
                MinimalModeSidebarChromeHoverState.shared.clear()
                return event
            }
            let isHovering = isMinimalModeSidebarChromeHoverCandidate(
                window: window,
                locationInWindow: event.locationInWindow
            )
            if isHovering {
                MinimalModeSidebarChromeHoverState.shared.setHovering(true, windowNumber: window.windowNumber)
            } else {
                MinimalModeSidebarChromeHoverState.shared.clear()
            }
            return event
        }
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            apply(to: window)
        }
    }

    private func hideStandardButtons(on window: NSWindow, hidden: Bool) {
        window.standardWindowButton(.closeButton)?.isHidden = hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = hidden
        window.standardWindowButton(.zoomButton)?.isHidden = hidden
    }

    private func applyTrafficLightOffset(on window: NSWindow, hidden: Bool) {
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            let offset = hidden ? NSPoint.zero : self.trafficLightOffset(for: window)
            self.applyTrafficLightOffsetNow(on: window, offset: offset)
        }
    }

    private func applyTrafficLightOffsetNow(on window: NSWindow, offset: NSPoint) {
        let key = ObjectIdentifier(window)
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        var baseFrames = trafficLightBaseFrames[key] ?? [:]

        for type in buttonTypes {
            guard let button = window.standardWindowButton(type) else { continue }
            if baseFrames[type] == nil || (baseFrames[type]?.isEmpty ?? true) {
                baseFrames[type] = button.frame
            }
        }

        trafficLightBaseFrames[key] = baseFrames

        for type in buttonTypes {
            guard let button = window.standardWindowButton(type), let base = baseFrames[type] else { continue }
            button.setFrameOrigin(NSPoint(x: base.origin.x + offset.x, y: base.origin.y + offset.y))
        }
    }

    private func trafficLightOffset(for window: NSWindow) -> NSPoint {
        guard window.identifier?.rawValue == "cmux.settings" else { return .zero }
        // Nudge controls slightly right/down to align with the custom Settings title row.
        return NSPoint(x: 7, y: -4)
    }

    private func shouldHideTrafficLights(for window: NSWindow) -> Bool {
        if window.isSheet {
            return true
        }
        if window.styleMask.contains(.docModalWindow) {
            return true
        }
        if window.styleMask.contains(.nonactivatingPanel) {
            return true
        }
        return false
    }
}

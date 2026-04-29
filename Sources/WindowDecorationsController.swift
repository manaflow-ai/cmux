import AppKit

final class WindowDecorationsController {
    private var observers: [NSObjectProtocol] = []
    private var didStart = false
    private var trafficLightBaseFrames: [ObjectIdentifier: [NSWindow.ButtonType: NSRect]] = [:]
    private var minimalModeTitlebarDoubleClickMonitor: Any?
    private var minimalModeSidebarChromeHoverMonitor: Any?
    private var lastMinimalModeTitlebarClick: MinimalModeTitlebarClickRecord?
    private let minimalModeSidebarTitlebarClickTargets = NSMapTable<NSWindow, MinimalModeSidebarControlActionView>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

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
        let enumerator = minimalModeSidebarTitlebarClickTargets.objectEnumerator()
        while let view = enumerator?.nextObject() as? NSView {
            view.removeFromSuperview()
        }
        WindowMouseMovedEventsCoordinator.disableOwner(self)
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
        if isMainWorkspaceWindow(window), WorkspacePresentationModeSettings.isMinimal() {
            WindowMouseMovedEventsCoordinator.enable(for: window, owner: self)
        } else {
            WindowMouseMovedEventsCoordinator.disable(for: window, owner: self)
        }
        let shouldHideButtons = shouldHideTrafficLights(for: window)
        hideStandardButtons(on: window, hidden: shouldHideButtons)
        applyTrafficLightOffset(on: window, hidden: shouldHideButtons)
        applyMinimalModeSidebarTitlebarClickTarget(to: window)
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
        ) { [weak self] event in
            guard let self else { return event }
            guard let target = self.minimalModeSidebarChromeEventTarget(for: event) else {
                #if DEBUG
                self.recordMinimalModeSidebarChromeMonitorForUITest(
                    event: event,
                    window: nil,
                    locationInWindow: nil,
                    isHovering: nil,
                    slot: nil
                )
                #endif
                MinimalModeSidebarChromeHoverState.shared.clear()
                return event
            }
            let window = target.window
            let locationInWindow = target.locationInWindow
            let isHovering = isMinimalModeSidebarChromeHoverCandidate(
                window: window,
                locationInWindow: locationInWindow
            )
            let actionSlot = minimalModeSidebarControlActionSlot(
                window: window,
                locationInWindow: locationInWindow
            )
            #if DEBUG
            recordMinimalModeSidebarChromeHoverForUITest(
                window: window,
                locationInWindow: locationInWindow,
                isHovering: isHovering,
                eventType: event.type
            )
            self.recordMinimalModeSidebarChromeMonitorForUITest(
                event: event,
                window: window,
                locationInWindow: locationInWindow,
                isHovering: isHovering,
                slot: actionSlot
            )
            #endif
            if event.type == .leftMouseDown,
               let slot = actionSlot {
                MinimalModeSidebarChromeHoverState.shared.setHovering(true, windowNumber: window.windowNumber)
                self.performMinimalModeSidebarControlAction(
                    slot,
                    window: window,
                    locationInWindow: locationInWindow
                )
                return nil
            }
            if isHovering {
                MinimalModeSidebarChromeHoverState.shared.setHovering(true, windowNumber: window.windowNumber)
            } else {
                MinimalModeSidebarChromeHoverState.shared.clear()
            }
            return event
        }
    }

    private func minimalModeSidebarChromeEventTarget(
        for event: NSEvent
    ) -> (window: NSWindow, locationInWindow: NSPoint)? {
        if let window = event.window {
            return (window, event.locationInWindow)
        }

        let screenPoint = NSEvent.mouseLocation
        for window in NSApp.windows.reversed() {
            guard isMainWorkspaceWindow(window),
                  window.isVisible,
                  !window.isMiniaturized,
                  window.frame.insetBy(dx: -1, dy: -1).contains(screenPoint) else {
                continue
            }
            let pointInWindow = window.convertFromScreen(
                NSRect(origin: screenPoint, size: .zero)
            ).origin
            return (window, pointInWindow)
        }
        return nil
    }

    #if DEBUG
    private func recordMinimalModeSidebarChromeMonitorForUITest(
        event: NSEvent,
        window: NSWindow?,
        locationInWindow: NSPoint?,
        isHovering: Bool?,
        slot: MinimalModeSidebarControlActionSlot?
    ) {
        guard ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" else { return }
        _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
            if event.type == .leftMouseDown {
                let count = (payload["minimalSidebarWindowMonitorLeftMouseDownCount"] as? String).flatMap(Int.init) ?? 0
                payload["minimalSidebarWindowMonitorLeftMouseDownCount"] = String(count + 1)
            }
            payload["minimalSidebarWindowMonitorLastEventType"] = String(describing: event.type)
            payload["minimalSidebarWindowMonitorLastEventWindowNumber"] = event.window.map { String($0.windowNumber) } ?? "nil"
            payload["minimalSidebarWindowMonitorLastTargetWindowNumber"] = window.map { String($0.windowNumber) } ?? "nil"
            payload["minimalSidebarWindowMonitorLastPoint"] = locationInWindow.map(windowDragHandleFormatPoint) ?? "nil"
            payload["minimalSidebarWindowMonitorLastScreenPoint"] = windowDragHandleFormatPoint(NSEvent.mouseLocation)
            payload["minimalSidebarWindowMonitorLastIsHovering"] = isHovering.map(String.init) ?? "nil"
            payload["minimalSidebarWindowMonitorLastSlot"] = slot?.debugName ?? "nil"
        }
    }
    #endif

    private func performMinimalModeSidebarControlAction(
        _ slot: MinimalModeSidebarControlActionSlot,
        window: NSWindow,
        locationInWindow: NSPoint,
        anchorView: NSView? = nil
    ) {
        #if DEBUG
        _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
            payload["minimalSidebarWindowMonitorLastAction"] = slot.debugName
        }
        #endif

        Task { @MainActor [weak window] in
            guard let window else { return }
            switch slot {
            case .toggleSidebar:
                _ = AppDelegate.shared?.toggleSidebarInActiveMainWindow(preferredWindow: window)
            case .showNotifications:
                let resolvedAnchorView = anchorView ?? NotificationsAnchorRegistry.shared.closestAnchor(
                    in: window,
                    to: locationInWindow
                )
                AppDelegate.shared?.toggleNotificationsPopover(animated: true, anchorView: resolvedAnchorView)
            case .newTab:
                let targetTabManager = AppDelegate.shared?.activeTabManagerForCommands(preferredWindow: window)
                _ = AppDelegate.shared?.performNewWorkspaceAction(
                    tabManager: targetTabManager,
                    debugSource: "titlebar.minimalSidebarControl"
                )
            }
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

    private func applyMinimalModeSidebarTitlebarClickTarget(to window: NSWindow) {
        let shouldInstall = isMainWorkspaceWindow(window)
            && WorkspacePresentationModeSettings.isMinimal()
            && !window.styleMask.contains(.fullScreen)
        guard shouldInstall,
              let titlebarView = window.standardWindowButton(.closeButton)?.superview else {
            removeMinimalModeSidebarTitlebarClickTarget(from: window)
            return
        }

        let target = minimalModeSidebarTitlebarClickTargets.object(forKey: window) ?? {
            let view = MinimalModeSidebarControlActionView()
            view.autoresizingMask = [.maxXMargin, .minYMargin, .maxYMargin]
            minimalModeSidebarTitlebarClickTargets.setObject(view, forKey: window)
            return view
        }()
        target.config = (TitlebarControlsStyle(rawValue: UserDefaults.standard.integer(forKey: "titlebarControlsStyle")) ?? .classic).config
        target.isEnabled = true
        target.requiresRevealedState = true
        target.telemetryPrefix = "minimalSidebarTitlebarClickTarget"
        target.onAction = { [weak self, weak window, weak target] slot, _, locationInWindow in
            let anchorView = target
            guard let self, let window else { return }
            self.performMinimalModeSidebarControlAction(
                slot,
                window: window,
                locationInWindow: locationInWindow,
                anchorView: anchorView
            )
        }

        if target.superview !== titlebarView {
            target.removeFromSuperview()
            titlebarView.addSubview(target, positioned: .above, relativeTo: nil)
        }

        let hostHeight = MinimalModeSidebarTitlebarControlsMetrics.hostHeight
        target.frame = NSRect(
            x: MinimalModeSidebarTitlebarControlsMetrics.leadingInset,
            y: max(0, (titlebarView.bounds.height - hostHeight) / 2),
            width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
            height: hostHeight
        )
    }

    private func removeMinimalModeSidebarTitlebarClickTarget(from window: NSWindow) {
        guard let target = minimalModeSidebarTitlebarClickTargets.object(forKey: window) else { return }
        target.removeFromSuperview()
        minimalModeSidebarTitlebarClickTargets.removeObject(forKey: window)
    }

    private func trafficLightOffset(for window: NSWindow) -> NSPoint {
        return .zero
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

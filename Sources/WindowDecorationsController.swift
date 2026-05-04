import AppKit

final class WindowDecorationsController {
    private var observers: [NSObjectProtocol] = []
    private var didStart = false
    private var minimalModeSidebarChromeHoverMonitor: Any?
    private var lastMinimalModeTitlebarClick: MinimalModeTitlebarClickRecord?
    private var lastKnownPresentationMode = WorkspacePresentationModeSettings.mode()
    private let minimalModeSidebarTitlebarClickTargets = NSMapTable<NSWindow, MinimalModeSidebarControlActionView>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    deinit {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
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
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyPresentationModeChangeIfNeeded()
        })
    }

    private func applyPresentationModeChangeIfNeeded() {
        let currentMode = WorkspacePresentationModeSettings.mode()
        guard currentMode != lastKnownPresentationMode else { return }
        lastKnownPresentationMode = currentMode
        attachToExistingWindows()
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
            self.applyMinimalModeSidebarTitlebarClickTarget(to: window)
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
            let controlsAreRevealed = MinimalModeSidebarChromeHoverState.shared.hoveredWindowNumber == window.windowNumber
                || NotificationsPopoverVisibilityState.shared.isShown(in: window.windowNumber)
            if event.type == .leftMouseDown,
               isHovering,
               controlsAreRevealed,
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

    func handleMinimalModeSidebarChromeMouseDown(window: NSWindow, event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else { return false }
        return handleMinimalModeSidebarChromeMouseDown(
            window: window,
            locationInWindow: event.locationInWindow,
            event: event
        )
    }

    func handleMinimalModeTitlebarDoubleClickMouseDown(event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown else { return false }
        guard let target = minimalModeSidebarChromeEventTarget(for: event) else { return false }
        return handleMinimalModeTitlebarDoubleClickMouseDown(
            window: target.window,
            locationInWindow: target.locationInWindow,
            event: event
        )
    }

    private func handleMinimalModeSidebarChromeMouseDown(
        window: NSWindow,
        locationInWindow: NSPoint,
        event: NSEvent
    ) -> Bool {
        applyMinimalModeSidebarTitlebarClickTarget(to: window)
        let isHovering = isMinimalModeSidebarChromeHoverCandidate(
            window: window,
            locationInWindow: locationInWindow
        )
        let controlsAreRevealed = MinimalModeSidebarChromeHoverState.shared.hoveredWindowNumber == window.windowNumber
            || NotificationsPopoverVisibilityState.shared.isShown(in: window.windowNumber)
        let actionSlot = minimalModeSidebarControlActionSlot(
            window: window,
            locationInWindow: locationInWindow
        )

        #if DEBUG
        recordMinimalModeSidebarChromeSendEventForUITest(
            window: window,
            locationInWindow: locationInWindow,
            isHovering: isHovering,
            slot: actionSlot
        )
        #endif

        guard isHovering, controlsAreRevealed, let actionSlot else { return false }
        MinimalModeSidebarChromeHoverState.shared.setHovering(true, windowNumber: window.windowNumber)
        performMinimalModeSidebarControlAction(
            actionSlot,
            window: window,
            locationInWindow: locationInWindow
        )
        return true
    }

    private func handleMinimalModeTitlebarDoubleClickMouseDown(
        window: NSWindow,
        locationInWindow: NSPoint,
        event: NSEvent
    ) -> Bool {
        let contentBounds = window.contentView?.bounds ?? NSRect(
            x: 0,
            y: 0,
            width: window.frame.width,
            height: window.frame.height
        )
        guard isMinimalModeWindowTitlebarClickCandidate(
            isMinimalMode: WorkspacePresentationModeSettings.isMinimal(),
            isFullScreen: window.styleMask.contains(.fullScreen),
            isMainWindow: isMainWorkspaceWindow(window),
            locationInWindow: locationInWindow,
            contentBounds: contentBounds,
            titlebarBandHeight: minimalModeTitlebarDoubleClickBandHeight(for: window)
        ) else {
            lastMinimalModeTitlebarClick = nil
            return false
        }
        guard !isMinimalModeTitlebarControlHit(window: window, locationInWindow: locationInWindow) else {
            lastMinimalModeTitlebarClick = nil
            return false
        }

        let windowNumber = window.windowNumber
        let isDoubleClick = minimalModeTitlebarClickFormsDoubleClick(
            clickCount: event.clickCount,
            timestamp: event.timestamp,
            locationInWindow: locationInWindow,
            windowNumber: windowNumber,
            previous: lastMinimalModeTitlebarClick,
            doubleClickInterval: NSEvent.doubleClickInterval,
            doubleClickIntervalTolerance: minimalModeTitlebarSyntheticDoubleClickTolerance
        )

        guard isDoubleClick else {
            lastMinimalModeTitlebarClick = MinimalModeTitlebarClickRecord(
                windowNumber: windowNumber,
                timestamp: event.timestamp,
                locationInWindow: locationInWindow
            )
            return false
        }

        lastMinimalModeTitlebarClick = nil
        let result = handleTitlebarDoubleClick(window: window, behavior: .standardAction)
        #if DEBUG
        cmuxDebugLog(
            "titlebar.minimalWindowDoubleClick.result=\(String(describing: result)) point=\(NSStringFromPoint(locationInWindow)) band=\(String(format: "%.1f", minimalModeTitlebarDoubleClickBandHeight(for: window)))"
        )
        #endif
        return result.consumesEvent
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

    #if DEBUG
    private func recordMinimalModeSidebarChromeSendEventForUITest(
        window: NSWindow,
        locationInWindow: NSPoint,
        isHovering: Bool,
        slot: MinimalModeSidebarControlActionSlot?
    ) {
        guard ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" else { return }
        _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
            let count = (payload["minimalSidebarWindowSendEventLeftMouseDownCount"] as? String).flatMap(Int.init) ?? 0
            payload["minimalSidebarWindowSendEventLeftMouseDownCount"] = String(count + 1)
            payload["minimalSidebarWindowSendEventLastWindowNumber"] = String(window.windowNumber)
            payload["minimalSidebarWindowSendEventLastPoint"] = windowDragHandleFormatPoint(locationInWindow)
            payload["minimalSidebarWindowSendEventLastIsHovering"] = String(isHovering)
            payload["minimalSidebarWindowSendEventLastSlot"] = slot?.debugName ?? "nil"
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

    private func applyMinimalModeSidebarTitlebarClickTarget(to window: NSWindow) {
        let shouldInstall = isMainWorkspaceWindow(window)
            && WorkspacePresentationModeSettings.isMinimal()
            && !window.styleMask.contains(.fullScreen)
            && minimalModeSidebarTitlebarControlsAreAvailable(in: window)
        guard shouldInstall,
              let contentView = window.contentView else {
            #if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" {
                _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                    payload["minimalSidebarTitlebarClickTargetInstalled"] = "false"
                    payload["minimalSidebarTitlebarClickTargetWindowNumber"] = String(window.windowNumber)
                }
            }
            #endif
            removeMinimalModeSidebarTitlebarClickTarget(from: window)
            return
        }

        let target = minimalModeSidebarTitlebarClickTargets.object(forKey: window) ?? {
            let view = MinimalModeSidebarControlActionView()
            view.autoresizingMask = [.maxXMargin, .minYMargin]
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

        if target.superview !== contentView {
            target.removeFromSuperview()
            contentView.addSubview(target, positioned: .above, relativeTo: nil)
        }

        let hostHeight = MinimalModeSidebarTitlebarControlsMetrics.hostHeight
        let contentBounds = contentView.bounds
        let targetY = contentView.isFlipped ? contentBounds.minY : max(0, contentBounds.maxY - hostHeight)
        target.frame = NSRect(
            x: MinimalModeSidebarTitlebarControlsMetrics.leadingInset,
            y: targetY,
            width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
            height: hostHeight
        )

        #if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" {
            _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                payload["minimalSidebarTitlebarClickTargetInstalled"] = "true"
                payload["minimalSidebarTitlebarClickTargetWindowNumber"] = String(window.windowNumber)
                payload["minimalSidebarTitlebarClickTargetFrameInWindow"] = NSStringFromRect(target.convert(target.bounds, to: nil))
                payload["minimalSidebarTitlebarClickTargetContentBounds"] = NSStringFromRect(contentBounds)
            }
        }
        #endif
    }

    private func removeMinimalModeSidebarTitlebarClickTarget(from window: NSWindow) {
        guard let target = minimalModeSidebarTitlebarClickTargets.object(forKey: window) else { return }
        target.removeFromSuperview()
        minimalModeSidebarTitlebarClickTargets.removeObject(forKey: window)
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

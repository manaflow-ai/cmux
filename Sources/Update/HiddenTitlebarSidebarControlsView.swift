import AppKit
import Bonsplit
import SwiftUI


// MARK: - Minimal-mode hidden titlebar sidebar controls
private struct TitlebarControlsGapDragView: NSViewRepresentable {
    let config: TitlebarControlsStyleConfig

    func makeNSView(context: Context) -> GapDragView {
        let view = GapDragView()
        view.config = config
        return view
    }

    func updateNSView(_ nsView: GapDragView, context: Context) {
        nsView.config = config
    }

    final class GapDragView: NSView {
        var config = TitlebarControlsStyle.classic.config

        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .leftMouseDown else { return nil }
            guard bounds.contains(point) else { return nil }
            guard !TitlebarControlsHitRegions.pointFallsInButtonColumn(point, config: config) else {
                return nil
            }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                let action = performStandardTitlebarDoubleClick(window: window)
                if action != nil {
                    return
                }
            }

            guard !isWindowDragSuppressed(window: window) else { return }

            if let window {
                withTemporaryWindowMovableEnabled(window: window) {
                    window.performDrag(with: event)
                }
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

private struct MinimalModeTitlebarButtonHitRegionView: NSViewRepresentable {
    let config: TitlebarControlsStyleConfig

    func makeNSView(context: Context) -> ButtonHitRegionView {
        let view = ButtonHitRegionView()
        view.config = config
        return view
    }

    func updateNSView(_ nsView: ButtonHitRegionView, context: Context) {
        nsView.config = config
        MinimalModeTitlebarControlHitRegionRegistry.register(nsView)
    }

    final class ButtonHitRegionView: NSView, MinimalModeSidebarControlActionHitRegionProviding {
        var config = TitlebarControlsStyle.classic.config

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                MinimalModeTitlebarControlHitRegionRegistry.unregister(self)
            } else {
                MinimalModeTitlebarControlHitRegionRegistry.register(self)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func containsMinimalModeTitlebarControlHit(localPoint: NSPoint) -> Bool {
            minimalModeSidebarControlActionSlot(localPoint: localPoint) != nil
        }

        func minimalModeSidebarControlActionSlot(localPoint: NSPoint) -> MinimalModeSidebarControlActionSlot? {
            TitlebarControlsHitRegions.sidebarActionSlot(at: localPoint, config: config)
        }

        deinit {
            MinimalModeTitlebarControlHitRegionRegistry.unregister(self)
        }
    }
}

struct HiddenTitlebarSidebarControlsView: View {
    let notificationStore: TerminalNotificationStore
    let onToggleSidebar: () -> Void
    let onToggleNotifications: (NSView?) -> Void
    let onNewTab: () -> Void
    let onFocusHistoryBack: () -> Void
    let onFocusHistoryForward: () -> Void
    @State private var viewModel = TitlebarControlsViewModel()
    private let popoverVisibilityState = NotificationsPopoverVisibilityState.shared
    @State private var isHoveringHost = false
    @State private var isHoveringWindowChrome = false
    @State private var hostWindowNumber: Int?
    @AppStorage("titlebarControlsStyle") private var styleRawValue = TitlebarControlsStyle.classic.rawValue

    private var shouldPinControls: Bool {
        isHoveringHost || isHoveringWindowChrome || popoverVisibilityState.isShown(in: hostWindowNumber)
    }

    var body: some View {
        let style = TitlebarControlsStyle(rawValue: styleRawValue) ?? .classic

        ZStack(alignment: .leading) {
            WindowAccessor { window in
                let nextWindowNumber = window.windowNumber
                let nextHoveringWindowChrome = MinimalModeSidebarChromeHoverState.shared.hoveredWindowNumber == nextWindowNumber
                if hostWindowNumber != nextWindowNumber || isHoveringWindowChrome != nextHoveringWindowChrome {
                    DispatchQueue.main.async {
                        if hostWindowNumber != nextWindowNumber {
                            hostWindowNumber = nextWindowNumber
                        }
                        if isHoveringWindowChrome != nextHoveringWindowChrome {
                            isHoveringWindowChrome = nextHoveringWindowChrome
                        }
                    }
                }
                #if DEBUG
                TitlebarChromeUITestRecorder.recordTrafficLightFrames(window: window)
                _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                    payload["minimalSidebarHostWindowNumber"] = String(nextWindowNumber)
                    payload["minimalSidebarHostPinned"] = String(
                        isHoveringHost || nextHoveringWindowChrome || popoverVisibilityState.isShown(in: nextWindowNumber)
                    )
                }
                #endif
            }
            .frame(
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
            )
            .allowsHitTesting(false)

            TitlebarControlsView(
                notificationStore: notificationStore,
                viewModel: viewModel,
                onToggleSidebar: onToggleSidebar,
                onToggleNotifications: { [viewModel] in
                    onToggleNotifications(viewModel.notificationsAnchorView)
                },
                onNewTab: onNewTab,
                onFocusHistoryBack: onFocusHistoryBack,
                onFocusHistoryForward: onFocusHistoryForward,
                visibilityMode: .alwaysVisible
            )
            .frame(
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight,
                alignment: .leading
            )
            .opacity(shouldPinControls ? 1 : 0)
            .allowsHitTesting(shouldPinControls)
            .accessibilityHidden(true)
            .animation(.easeInOut(duration: 0.14), value: shouldPinControls)

            TitlebarControlsGapDragView(config: style.config)
                .frame(
                    width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                    height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
                )

            MinimalModeSidebarControlActionProxyView(
                config: style.config,
                requiresRevealedState: true
            ) { slot, anchorView, _ in
                switch slot {
                case .toggleSidebar:
                    onToggleSidebar()
                case .showNotifications:
                    onToggleNotifications(anchorView)
                case .newTab:
                    onNewTab()
                case .focusHistoryBack:
                    let availability = focusHistoryNavigationAvailability(
                        preferredWindow: hostWindowForFocusHistoryNavigation
                    )
                    guard availability.canNavigateBack else { return }
                    onFocusHistoryBack()
                case .focusHistoryForward:
                    let availability = focusHistoryNavigationAvailability(
                        preferredWindow: hostWindowForFocusHistoryNavigation
                    )
                    guard availability.canNavigateForward else { return }
                    onFocusHistoryForward()
                }
            }
            .frame(
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
            )

            PassthroughHoverTrackingView(capturesPassiveHits: !shouldPinControls) { isHoveringHost = $0 }
            .frame(
                width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
                height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight
            )

        }
        .frame(
            width: MinimalModeSidebarTitlebarControlsMetrics.hostWidth,
            height: MinimalModeSidebarTitlebarControlsMetrics.hostHeight,
            alignment: .leading
        )
        .background(MinimalModeTitlebarButtonHitRegionView(config: style.config))
        .onChange(of: MinimalModeSidebarChromeHoverState.shared.hoveredWindowNumber, initial: true) { _, hoveredWindowNumber in
            isHoveringWindowChrome = hostWindowNumber == hoveredWindowNumber
            #if DEBUG
            _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                payload["minimalSidebarObservedHoverWindowNumber"] = hoveredWindowNumber.map(String.init) ?? "nil"
                payload["minimalSidebarObservedHostWindowNumber"] = hostWindowNumber.map(String.init) ?? "nil"
                payload["minimalSidebarObservedPinned"] = String(shouldPinControls)
            }
            #endif
        }
        .onDisappear {
            isHoveringHost = false
            isHoveringWindowChrome = false
            if let hostWindowNumber {
                MinimalModeSidebarChromeHoverState.shared.setHovering(false, windowNumber: hostWindowNumber)
            }
            hostWindowNumber = nil
        }
    }

    @MainActor
    private var hostWindowForFocusHistoryNavigation: NSWindow? {
        if let hostWindowNumber,
           let hostWindow = NSApp.windows.first(where: { $0.windowNumber == hostWindowNumber }) {
            return hostWindow
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }
}

enum TitlebarControlsVisibilityMode {
    case alwaysVisible
    case onHover
}

func minimalModePassthroughHoverTrackerCapturesHit(
    capturesPassiveHits: Bool,
    eventType: NSEvent.EventType?,
    pressedMouseButtons: Int,
    boundsContainsPoint: Bool
) -> Bool {
    guard boundsContainsPoint, pressedMouseButtons == 0 else { return false }
    switch eventType {
    case nil, .mouseMoved, .mouseEntered, .mouseExited:
        return capturesPassiveHits
    default:
        return false
    }
}

private struct PassthroughHoverTrackingView: NSViewRepresentable {
    let capturesPassiveHits: Bool
    let onHoverChanged: (Bool) -> Void
    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.capturesPassiveHits = capturesPassiveHits
        view.onHoverChanged = onHoverChanged
        return view
    }
    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.capturesPassiveHits = capturesPassiveHits
        nsView.onHoverChanged = onHoverChanged
    }

    final class TrackingView: NSView {
        var capturesPassiveHits = true
        var onHoverChanged: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?
        private var localMouseMonitor: Any?
        private var isHovering = false
        private weak var mouseMovedWindow: NSWindow?
        private var isTrackingMouseMovedEvents = false

        deinit {
            removeLocalMouseMonitor()
            stopMouseMovedTracking()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard bounds.contains(point) else { return nil }
            guard NSEvent.pressedMouseButtons == 0 else { return nil }
            let event = NSApp.currentEvent
            switch event?.type {
            case .none:
                refreshHoverForHitTest(event: event)
            case .mouseMoved, .mouseEntered, .mouseExited:
                refreshHoverForHitTest(event: event)
            default:
                return nil
            }
            return minimalModePassthroughHoverTrackerCapturesHit(
                capturesPassiveHits: capturesPassiveHits,
                eventType: event?.type,
                pressedMouseButtons: NSEvent.pressedMouseButtons,
                boundsContainsPoint: true
            ) ? self : nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                refreshMouseMovedTracking(in: window)
                installLocalMouseMonitorIfNeeded()
                updateHoverFromCurrentMouseLocation()
                recordFrameForUITest()
            } else {
                stopMouseMovedTracking()
                removeLocalMouseMonitor()
                emitHoverChanged(false)
            }
        }

        private func refreshMouseMovedTracking(in window: NSWindow) {
            guard !isTrackingMouseMovedEvents || mouseMovedWindow !== window else { return }
            stopMouseMovedTracking()
            WindowMouseMovedEventsCoordinator.enable(for: window, owner: self)
            mouseMovedWindow = window
            isTrackingMouseMovedEvents = true
        }

        private func stopMouseMovedTracking() {
            if let mouseMovedWindow {
                WindowMouseMovedEventsCoordinator.disable(for: mouseMovedWindow, owner: self)
            } else {
                WindowMouseMovedEventsCoordinator.disableOwner(self)
            }
            mouseMovedWindow = nil
            isTrackingMouseMovedEvents = false
        }

        override func layout() {
            super.layout()
            recordFrameForUITest()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            updateHover(from: event)
        }

        override func mouseExited(with event: NSEvent) {
            updateHover(from: event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateHover(from: event)
        }

        private func installLocalMouseMonitorIfNeeded() {
            guard localMouseMonitor == nil else { return }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDown, .leftMouseDragged]
            ) { [weak self] event in
                self?.updateHover(from: event)
                return event
            }
        }

        private func removeLocalMouseMonitor() {
            if let localMouseMonitor {
                NSEvent.removeMonitor(localMouseMonitor)
                self.localMouseMonitor = nil
            }
        }

        private func updateHover(from event: NSEvent) {
            guard let window else {
                emitHoverChanged(false)
                return
            }

            let pointInWindow = event.window === window
                ? event.locationInWindow
                : window.mouseLocationOutsideOfEventStream
            let pointInView = convert(pointInWindow, from: nil)
            emitHoverChanged(bounds.insetBy(dx: -1, dy: -1).contains(pointInView))
        }

        private func updateHoverFromCurrentMouseLocation() {
            guard let window else {
                emitHoverChanged(false)
                return
            }
            let pointInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            emitHoverChanged(bounds.insetBy(dx: -1, dy: -1).contains(pointInView))
        }

        private func refreshHoverForHitTest(event: NSEvent?) {
            if let event {
                updateHover(from: event)
            } else {
                updateHoverFromCurrentMouseLocation()
            }
        }

        private func emitHoverChanged(_ newValue: Bool) {
            guard isHovering != newValue else { return }
            isHovering = newValue
            onHoverChanged?(newValue)
        }

        private func recordFrameForUITest() {
            #if DEBUG
            guard ProcessInfo.processInfo.environment["CMUX_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" else { return }
            guard window != nil else { return }
            let frameInWindow = convert(bounds, to: nil)
            _ = CmuxUITestCapture.mutateJSONObjectIfConfigured(envKey: "CMUX_UI_TEST_BONSPLIT_TAB_DRAG_PATH") { payload in
                payload["minimalSidebarHostFrameInWindow"] = NSStringFromRect(frameInWindow)
            }
            #endif
        }
    }
}


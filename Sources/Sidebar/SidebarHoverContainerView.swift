import AppKit

@MainActor
final class SidebarHoverContainerView: NSView {
    var coordinator: SidebarHoverCoordinator

    private var trackingArea: NSTrackingArea?
    private weak var mouseMovedWindow: NSWindow?
    private var isTrackingMouseMovedEvents = false
    private var activationObservers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []

    init(coordinator: SidebarHoverCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        coordinator.containerView = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        coordinator.reconcileCurrentPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator.reconcileCurrentPointer()
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator.reconcileCurrentPointer()
    }

    override func mouseExited(with event: NSEvent) {
        coordinator.pointerExitedContainer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshLifecycleBindings()
    }

    func refreshLifecycleBindings() {
        coordinator.containerView = self
        if let window {
            refreshMouseMovedTracking(in: window)
            installActivationObserversIfNeeded()
            installWindowObserversIfNeeded(for: window)
            coordinator.reconcileCurrentPointer()
        } else {
            removeActivationObservers()
            removeWindowObservers()
            stopMouseMovedTracking()
            coordinator.clearHover()
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

    private func installActivationObserversIfNeeded() {
        guard activationObservers.isEmpty else { return }
        let notificationCenter = NotificationCenter.default
        activationObservers = [
            notificationCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.coordinator.clearHover()
            },
            notificationCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.coordinator.reconcileCurrentPointer()
            }
        ]
    }

    private func removeActivationObservers() {
        guard !activationObservers.isEmpty else { return }
        let notificationCenter = NotificationCenter.default
        for observer in activationObservers {
            notificationCenter.removeObserver(observer)
        }
        activationObservers.removeAll()
    }

    private func installWindowObserversIfNeeded(for window: NSWindow) {
        guard windowObservers.isEmpty else { return }
        let notificationCenter = NotificationCenter.default
        windowObservers = [
            notificationCenter.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: nil
            ) { [weak self] _ in
                self?.coordinator.reconcileCurrentPointer()
            },
            notificationCenter.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: nil
            ) { [weak self] _ in
                self?.coordinator.reconcileCurrentPointer()
            },
            notificationCenter.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: nil
            ) { [weak self] _ in
                self?.coordinator.reconcileCurrentPointer()
            }
        ]
    }

    private func removeWindowObservers() {
        guard !windowObservers.isEmpty else { return }
        let notificationCenter = NotificationCenter.default
        for observer in windowObservers {
            notificationCenter.removeObserver(observer)
        }
        windowObservers.removeAll()
    }
}

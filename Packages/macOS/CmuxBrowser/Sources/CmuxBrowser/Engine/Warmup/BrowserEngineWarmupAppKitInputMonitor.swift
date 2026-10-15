public import AppKit

/// The live ``BrowserEngineWarmupInputMonitoring``: a local AppKit event
/// monitor plus the menu tracking notification.
@MainActor
public final class BrowserEngineWarmupAppKitInputMonitor: BrowserEngineWarmupInputMonitoring {
    private var eventMonitor: Any?
    private var menuObserver: (any NSObjectProtocol)?
    private let notificationCenter: NotificationCenter

    /// Creates a monitor.
    /// - Parameter notificationCenter: Where `NSMenu.didEndTrackingNotification`
    ///   is posted; injectable for tests.
    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    public var isTrackingMenu: Bool { RunLoop.main.currentMode == .eventTracking }

    public func start(onInput: @escaping @MainActor () -> Void, onMenuTrackingEnd: @escaping @MainActor () -> Void) {
        stop()
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .scrollWheel, .mouseMoved,
        ]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated { onInput() }
            return event
        }
        menuObserver = notificationCenter.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onMenuTrackingEnd() }
        }
    }

    public func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let menuObserver { notificationCenter.removeObserver(menuObserver) }
        menuObserver = nil
    }
}

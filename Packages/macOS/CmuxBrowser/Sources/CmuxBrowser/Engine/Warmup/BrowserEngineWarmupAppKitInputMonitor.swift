public import AppKit

/// The live ``BrowserEngineWarmupInputMonitoring``: a local AppKit event
/// monitor plus the menu tracking notification.
///
/// ``isTrackingMenu`` is true for any event-tracking run loop, not only a
/// menu: a held button or a dragged scroller counts too. Mouse-up events are
/// reported as input so the warmup re-arms when such a loop ends without a
/// menu notification.
@MainActor
public final class BrowserEngineWarmupAppKitInputMonitor: BrowserEngineWarmupInputMonitoring {
    // Written only on the main actor; deinit reads them to unregister a
    // monitor whose owner was released without calling `stop()`.
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var menuObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private let notificationCenter: NotificationCenter

    /// Creates a monitor.
    /// - Parameter notificationCenter: Where `NSMenu.didEndTrackingNotification`
    ///   is posted; injectable for tests.
    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let menuObserver { notificationCenter.removeObserver(menuObserver) }
    }

    public var isTrackingMenu: Bool { RunLoop.main.currentMode == .eventTracking }

    public func start(onInput: @escaping @MainActor () -> Void, onMenuTrackingEnd: @escaping @MainActor () -> Void) {
        stop()
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
            .leftMouseDragged, .scrollWheel, .mouseMoved,
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

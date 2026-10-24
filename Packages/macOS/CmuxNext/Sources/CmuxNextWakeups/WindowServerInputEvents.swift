public import AppKit

/// The production ``SessionInputEvents``: `CGEventSource`'s combined session state, `NSApp`, and
/// one local event monitor for the dispatched key-downs and mouse-downs.
@MainActor
public final class WindowServerInputEvents: SessionInputEvents {
    private var monitor: Any?

    public init() {}

    public func secondsSinceLastEvent(_ type: CGEventType) -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
    }

    public var isAppActive: Bool { NSApp?.isActive ?? false }

    public func observeDispatch(_ dispatched: @escaping @MainActor @Sendable (TimeInterval) -> Void) -> Bool {
        guard monitor == nil else { return true }
        guard NSApp != nil else { return false }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            // main-proof: AppKit calls local monitors on the main thread, inside event dispatch
            MainActor.assumeIsolated { dispatched(event.timestamp) }
            return event
        }
        return true
    }
}

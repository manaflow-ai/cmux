public import AppKit
import CmuxNextCompat

/// The production ``SessionInputEvents``: `CGEventSource`'s combined session state, `NSApp`, and
/// one local event monitor for the input events AppKit dispatches.
@MainActor
public final class WindowServerInputEvents: SessionInputEvents {
    private var monitor: Any?
    /// The menus tracking now (``MenuTracking``, started with the dispatch monitor; it lives as long
    /// as this source, the app's one budget's).
    private var menus: MenuTracking?
    private var trackingMenus: Set<ObjectIdentifier> = []
    /// `kCGAnyInputEventType` (`~0`, a C macro Swift does not import).
    private let anyInput = CGEventType(rawValue: ~0)

    public init() {}

    public func secondsSinceLastInput() -> TimeInterval {
        // Without the any-input type the answer is "just now", which sends the caller to the
        // per-type queries: slower, never wrong.
        guard let anyInput else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    public func secondsSinceLastEvent(_ type: CGEventType) -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
    }

    public var isAppActive: Bool { NSApp?.isActive ?? false }

    /// A menu posted its begin and not yet its end, and the main run loop is in its tracking mode.
    /// Out of that mode no menu tracks, so a lost end notice never leaves this on.
    public var isMenuTracking: Bool {
        !trackingMenus.isEmpty && RunLoop.main.currentMode == .eventTracking
    }

    public func observeDispatch(_ dispatched: @escaping @MainActor @Sendable (TimeInterval, Bool) -> Void) -> Bool {
        guard monitor == nil else { return true }
        guard NSApp != nil else { return false }
        let menus = MenuTracking()
        menus.subscribe { [weak self] change in
            switch change {
            case .began(let menu): self?.trackingMenus.insert(ObjectIdentifier(menu))
            case .ended(let menu): self?.trackingMenus.remove(ObjectIdentifier(menu))
            }
        }
        self.menus = menus
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                           .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                           .otherMouseDragged, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            // main-proof: AppKit calls local monitors on the main thread, inside event dispatch
            MainActor.assumeIsolated { dispatched(event.timestamp, isKeyOrClick(event.type)) }
            return event
        }
        return true
    }
}

/// Whether `type` is what a person waits on: a key-down or a mouse-button-down.
private func isKeyOrClick(_ type: NSEvent.EventType) -> Bool {
    switch type {
    case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown: true
    default: false
    }
}

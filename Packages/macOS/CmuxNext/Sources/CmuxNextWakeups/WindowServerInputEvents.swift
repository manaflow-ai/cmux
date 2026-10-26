public import AppKit

/// The production ``SessionInputEvents``: `CGEventSource`'s combined session state, `NSApp`, the
/// main screen, and one local event monitor for the input events AppKit dispatches.
@MainActor
public final class WindowServerInputEvents: SessionInputEvents {
    private var monitor: Any?
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

    public var refreshInterval: TimeInterval { NSScreen.main?.minimumRefreshInterval ?? 1.0 / 60 }

    public func observeDispatch(_ dispatched: @escaping @MainActor @Sendable (SessionInputPending.Dispatched) -> Void) -> Bool {
        guard monitor == nil else { return true }
        guard NSApp != nil else { return false }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                           .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                           .otherMouseDragged, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            // main-proof: AppKit calls local monitors on the main thread, inside event dispatch
            MainActor.assumeIsolated { dispatched(SessionInputPending.Dispatched(timestamp: event.timestamp, kind: kind(of: event))) }
            return event
        }
        return true
    }
}

/// What ``SessionInputPending`` needs to know about a dispatched event.
private func kind(of event: NSEvent) -> SessionInputPending.Dispatched.Kind {
    switch event.type {
    case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown: .keyOrClick
    case .leftMouseDragged: .leftDrag
    case .scrollWheel: .scroll(gestureContinues: gestureContinues(phase: event.phase, momentum: event.momentumPhase))
    default: .other
    }
}

/// Whether a scroll with these phases leaves a gesture running, so the next tick is part of it: a
/// began, changed or stationary phase or momentum phase. May-begin, ended, cancelled and a wheel
/// notch (no phase) end it: the next scroll begins one.
private func gestureContinues(phase: NSEvent.Phase, momentum: NSEvent.Phase) -> Bool {
    let running: NSEvent.Phase = [.began, .changed, .stationary]
    return !phase.isDisjoint(with: running) || !momentum.isDisjoint(with: running)
}

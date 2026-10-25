public import AppKit
import CmuxNextCompat

/// The ``FrameInputCoalescer`` of each window, and the application's hook for discrete input:
/// `sendEvent` calls ``willDispatch(_:)`` for every event, which flushes the pending continuous
/// work before a key or button is dispatched and ends unbuffered delivery on pointer up.
///
/// Owned by the application (one per process, injected into whoever posts); a window's coalescer
/// is made on first use and dropped when the window closes.
@MainActor
public final class FrameInputCoalescers {
    public typealias Factory = @MainActor (NSWindow) -> FrameInputCoalescer

    private struct Entry {
        weak var window: NSWindow?
        let coalescer: FrameInputCoalescer
        let closeObserver: MainActorObservation
    }

    private let make: Factory
    private var entries: [ObjectIdentifier: Entry] = [:]
    /// The windows with pending work: a key-down with none costs one emptiness check.
    private var withPending: Set<ObjectIdentifier> = []

    /// `make` builds a window's coalescer (default: on the window's ``FrameScheduler``).
    public init(make: Factory? = nil) {
        if let make {
            self.make = make
        } else {
            self.make = { window in FrameInputCoalescer(scheduler: FrameScheduler.forWindow(window)) }
        }
    }

    /// `window`'s coalescer, made on first use.
    public func coalescer(for window: NSWindow) -> FrameInputCoalescer {
        let key = ObjectIdentifier(window)
        if let entry = entries[key], entry.window === window { return entry.coalescer }
        drop(key)
        let coalescer = make(window)
        coalescer.onPendingChange = { [weak self] pending in self?.pendingChanged(key, pending) }
        let closeObserver = MainActorObservation(NSWindow.willCloseNotification, object: window) { [weak self] in
            self?.drop(key)
        }
        entries[key] = Entry(window: window, coalescer: coalescer, closeObserver: closeObserver)
        return coalescer
    }

    /// Some window has continuous input waiting for its frame.
    public var hasPending: Bool { !withPending.isEmpty }

    /// Called by `sendEvent` before it dispatches `type`: a discrete event flushes every window's
    /// pending work first; a pointer up also ends unbuffered delivery. Continuous events pass.
    public func willDispatch(_ type: NSEvent.EventType) {
        switch type {
        case .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            flushBeforeDiscreteInput()
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            for entry in entries.values { entry.coalescer.pointerUp() }
        default:
            return
        }
    }

    /// Delivers every window's pending continuous work now.
    public func flushBeforeDiscreteInput() {
        guard !withPending.isEmpty else { return }
        for key in withPending { entries[key]?.coalescer.flushBeforeDiscreteInput() }
    }

    private func pendingChanged(_ key: ObjectIdentifier, _ pending: Bool) {
        if pending {
            withPending.insert(key)
        } else {
            withPending.remove(key)
        }
    }

    private func drop(_ key: ObjectIdentifier) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.coalescer.invalidate()
        withPending.remove(key)
    }
}

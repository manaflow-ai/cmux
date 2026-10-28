public import AppKit

/// The application's hook into every window's ``FrameInputCoalescer``: `sendEvent` calls
/// ``willDispatch(_:)`` for every event, which flushes the pending continuous work before a key
/// or button is dispatched and ends unbuffered delivery on pointer up.
///
/// One per application, injected into whoever posts. A window's coalescer is its
/// ``FrameScheduler/input``, so it closes with the window's scheduler; this type only tracks which
/// coalescers have work and which ones were handed out.
@MainActor
public final class FrameInputCoalescers {
    /// Makes the coalescer of a window (the window's ``FrameScheduler/input``).
    public typealias Factory = @MainActor (NSWindow) -> FrameInputCoalescer

    private struct Weak {
        weak var value: FrameInputCoalescer?
    }

    private let make: Factory
    /// The coalescers handed out (pointer up ends their unbuffered delivery).
    private var known: [ObjectIdentifier: Weak] = [:]
    /// The coalescers with pending work: a key-down with none costs one emptiness check.
    private var withPending: [ObjectIdentifier: Weak] = [:]

    /// `make` gives a window's coalescer (default: the window scheduler's ``FrameScheduler/input``).
    public init(make: Factory? = nil) {
        if let make {
            self.make = make
        } else {
            self.make = { window in FrameScheduler.forWindow(window).input }
        }
    }

    /// `window`'s coalescer.
    public func coalescer(for window: NSWindow) -> FrameInputCoalescer {
        let coalescer = make(window)
        let key = ObjectIdentifier(coalescer)
        if known[key]?.value !== coalescer {
            known = known.filter { $0.value.value != nil }
            known[key] = Weak(value: coalescer)
            coalescer.onPendingChange = { [weak self, weak coalescer] pending in
                guard let coalescer else { return }
                self?.pendingChanged(coalescer, pending)
            }
            if coalescer.hasPending { pendingChanged(coalescer, true) }
        }
        return coalescer
    }

    /// Some window has continuous input waiting for its frame.
    public var hasPending: Bool { !withPending.isEmpty }

    /// Called by `sendEvent` before any tap observer sees `type`: a discrete event flushes every
    /// window's pending work first; a pointer up also ends unbuffered delivery. Continuous events pass.
    public func willDispatch(_ type: NSEvent.EventType) { // perf-hot: 100ns main-turn (every event's dispatch)
        switch type {
        case .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .swipe, .smartMagnify:
            flushBeforeDiscreteInput()
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            for entry in known.values { entry.value?.pointerUp() }
        default:
            return
        }
    }

    /// Delivers every window's pending continuous work now.
    public func flushBeforeDiscreteInput() {
        guard !withPending.isEmpty else { return }
        for entry in Array(withPending.values) { entry.value?.flushBeforeDiscreteInput() }
    }

    private func pendingChanged(_ coalescer: FrameInputCoalescer, _ pending: Bool) {
        let key = ObjectIdentifier(coalescer)
        if pending {
            withPending[key] = Weak(value: coalescer)
        } else {
            withPending[key] = nil
        }
    }
}

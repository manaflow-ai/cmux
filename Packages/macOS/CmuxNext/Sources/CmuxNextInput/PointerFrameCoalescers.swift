public import AppKit
public import CmuxNextWakeups

/// The application's ``PointerFrameCoalescer``, one per window, made on first use: one per
/// application, injected into whoever posts (a resize handle's drag, a hover tracker). Each window's
/// coalescer flushes its pending input before every key, flags, button and gesture event the tap
/// dispatches in that window (Chromium's `ShouldFlushQueue`, `main_thread_event_queue.cc`).
///
/// ```swift
/// let frames = PointerFrameCoalescers(tap: inputTap, mainWork: mainWork)
/// let drag = frames.coalescer(for: window).consumer(owner: "DividerHandleView") { input in apply(input) }
/// ```
@MainActor
public final class PointerFrameCoalescers {
    public typealias Factory = @MainActor (NSWindow) -> PointerFrameCoalescer

    private struct Entry {
        weak var window: NSWindow?
        let coalescer: PointerFrameCoalescer
        /// Flushes the window's pending input before each discrete event (nil with no tap: tests).
        let flushes: InputSubscription?
    }

    private let tap: InputEventTap?
    private let make: Factory
    private var entries: [ObjectIdentifier: Entry] = [:]

    /// `make` gives a window's coalescer; `tap` (nil in tests) flushes it before discrete input.
    public init(tap: InputEventTap?, make: @escaping Factory) {
        self.tap = tap
        self.make = make
    }

    /// Coalescers on each window's ``FrameScheduler``, with a fallback timer on `mainWork`'s deadline queue.
    public convenience init(tap: InputEventTap, mainWork: MainWorkScheduler) {
        self.init(tap: tap) { window in
            // timer-class-allow: PointerFrameCoalescer's spec'd fallback (p04-input-030), armed only while input waits on a stopped link, and it delivers that input
            let fallback = DemandTimer(owner: "PointerFrameCoalescer.fallback", mainWork: mainWork)
            return PointerFrameCoalescer(scheduler: .forWindow(window), fallback: fallback)
        }
    }

    /// `window`'s coalescer.
    public func coalescer(for window: NSWindow) -> PointerFrameCoalescer {
        let key = ObjectIdentifier(window)
        if let entry = entries[key], entry.window === window { return entry.coalescer }
        dropGoneWindows()
        let coalescer = make(window)
        let flushes = tap.map { coalescer.flushBeforeDiscreteInput(on: $0, window: .window(window)) }
        entries[key] = Entry(window: window, coalescer: coalescer, flushes: flushes)
        return coalescer
    }

    /// Lets go of the coalescers of windows that are gone (on a new window's first use: no timer).
    private func dropGoneWindows() {
        for (key, entry) in entries where entry.window == nil {
            entry.coalescer.invalidate()
            entries[key] = nil
        }
    }
}

public import Foundation
import CoreGraphics

/// The production check: the window server's time of the last key-down or mouse-button event in
/// this login session, against the timestamp of the last such event AppKit dispatched in this app.
///
/// An event that the HID system generated after the last one the app dispatched is still on its
/// way through the event queue: the app is active, so it is ours. Mouse moves, drags and scroll
/// ticks are left out on purpose: they stream at the pointer's rate, and yielding to each would
/// starve visible updates; a key or a click is what a person waits on. An event the app never
/// dispatches (taken by another process while the app turns inactive) stops counting after
/// ``staleAfter``, so it cannot hold batches back.
///
/// Each check is one window-server query in the common case: the newest input event of any type
/// (``SessionInputEvents/secondsSinceLastInput()``). When that event is no newer than the last one
/// AppKit dispatched here, or is stale, no key or click can be pending (each is an input event, and
/// the app's event queue is first in, first out), so the check ends there. Only when some input
/// is still on its way does it ask per type (key-down first, then each mouse button).
///
/// ```swift
/// // The app:
/// let budget = MainFrameBudget(input: SessionInputPending(), signposts: true)
/// // A test, with its own window-server times and dispatch record:
/// let events = FakeSessionEvents()
/// let input = SessionInputPending(events: events)
/// ```
@MainActor
public final class SessionInputPending: InputPendingSource {
    /// How long an undispatched event counts as pending: two 60 Hz frames, longer than any
    /// dispatch delay the budget allows, so a real pending event is never missed while a lost one
    /// defers at most two frames of batches.
    public static let staleAfter: TimeInterval = 2.0 / 60.0

    private static let eventTypes: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    private let events: any SessionInputEvents
    /// The newest key-down or mouse-button-down AppKit dispatched here.
    private var lastDispatched: TimeInterval = 0
    /// The newest input event of any type AppKit dispatched here.
    private var lastDispatchedAny: TimeInterval = 0
    private var observing = false

    /// - Parameter events: The window server and AppKit (tests: a fake that reports its own event
    ///   times and dispatches).
    public init(events: any SessionInputEvents = WindowServerInputEvents()) {
        self.events = events
    }

    /// Records that AppKit dispatched an input event with `timestamp` (seconds since boot).
    private func dispatched(_ timestamp: TimeInterval, isKeyOrClick: Bool) {
        lastDispatchedAny = max(lastDispatchedAny, timestamp)
        if isKeyOrClick { lastDispatched = max(lastDispatched, timestamp) }
    }

    public func hasPendingInput(uptime: TimeInterval) -> Bool {
        if !observing {
            observing = events.observeDispatch { [weak self] timestamp, isKeyOrClick in self?.dispatched(timestamp, isKeyOrClick: isKeyOrClick) }
        }
        guard events.isAppActive else { return false }
        // One query: nothing generated after the last dispatched event, or nothing recent, means no
        // key or click is on its way either (the event queue is first in, first out). Events a
        // tracking loop takes (a drag, a menu) never reach the monitor, so during one this answers
        // "maybe" and the per-type queries decide.
        guard Self.isPending(uptime - events.secondsSinceLastInput(), after: lastDispatchedAny, now: uptime) else { return false }
        for type in Self.eventTypes where Self.isPending(uptime - events.secondsSinceLastEvent(type), after: lastDispatched, now: uptime) {
            return true
        }
        return false
    }

    /// Whether an event generated at `generated` (seconds since boot) is newer than `dispatched`
    /// and recent enough at `now` to count. 1 ms: the HID time and the event's timestamp come from
    /// one clock but are rounded apart.
    private static func isPending(_ generated: TimeInterval, after dispatched: TimeInterval, now: TimeInterval) -> Bool {
        generated > dispatched + 0.001 && now - generated < staleAfter
    }
}

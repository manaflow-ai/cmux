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
    private var lastDispatched: TimeInterval = 0
    private var observing = false

    /// - Parameter events: The window server and AppKit (tests: a fake that reports its own event
    ///   times and dispatches).
    public init(events: any SessionInputEvents = WindowServerInputEvents()) {
        self.events = events
    }

    /// Records that AppKit dispatched an event with `timestamp` (seconds since boot).
    private func dispatched(_ timestamp: TimeInterval) {
        lastDispatched = max(lastDispatched, timestamp)
    }

    public func hasPendingInput(uptime: TimeInterval) -> Bool {
        if !observing {
            observing = events.observeDispatch { [weak self] timestamp in self?.dispatched(timestamp) }
        }
        guard events.isAppActive else { return false }
        var newest: TimeInterval = 0
        for type in Self.eventTypes {
            newest = max(newest, uptime - events.secondsSinceLastEvent(type))
        }
        // 1 ms: the HID time and the event's timestamp come from one clock but are rounded apart.
        return newest > lastDispatched + 0.001 && uptime - newest < Self.staleAfter
    }
}

public import AppKit

/// Tells ``MainFrameBudget`` whether a person's input is waiting for the main thread, so budgeted
/// work yields to it (Chrome's input-pending check before a scheduled task).
@MainActor
public protocol InputPendingSource: AnyObject {
    /// Whether a key or mouse-button event for this app has been generated but not dispatched yet.
    ///
    /// - Parameter uptime: Now, in seconds since boot (the `NSEvent.timestamp` base).
    func hasPendingInput(uptime: TimeInterval) -> Bool
}

/// Never reports pending input (tests that do not exercise the yield, headless hosts).
@MainActor
public final class NoInputPending: InputPendingSource {
    public init() {}
    public func hasPendingInput(uptime: TimeInterval) -> Bool { false }
}

/// The production check: the window server's time of the last key-down or mouse-button event in
/// this login session, against the timestamp of the last such event AppKit dispatched in this app.
///
/// An event that the HID system generated after the last one the app dispatched is still on its
/// way through the event queue: the app is active, so it is ours. Mouse moves, drags and scroll
/// ticks are left out on purpose: they stream at the pointer's rate, and yielding to each would
/// starve visible updates; a key or a click is what a person waits on. An event the app never
/// dispatches (taken by another process while the app turns inactive) stops counting after
/// ``staleAfter``, so it cannot hold batches back.
@MainActor
public final class SessionInputPending: InputPendingSource {
    /// How long an undispatched event counts as pending: two 60 Hz frames, longer than any
    /// dispatch delay the budget allows, so a real pending event is never missed while a lost one
    /// defers at most two frames of batches.
    public static let staleAfter: TimeInterval = 2.0 / 60.0

    private static let eventTypes: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    private var lastDispatched: TimeInterval = 0
    private var monitor: Any?

    public init() {}

    /// Installs the local event monitor that records dispatched events (once, on first use).
    private func installIfNeeded() {
        guard monitor == nil, NSApp != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            // main-proof: AppKit calls local monitors on the main thread, inside event dispatch
            MainActor.assumeIsolated { self?.lastDispatched = max(self?.lastDispatched ?? 0, event.timestamp) }
            return event
        }
    }

    public func hasPendingInput(uptime: TimeInterval) -> Bool {
        installIfNeeded()
        guard let app = NSApp, app.isActive else { return false }
        var newest: TimeInterval = 0
        for type in Self.eventTypes {
            let age = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
            newest = max(newest, uptime - age)
        }
        // 1 ms: the HID time and the event's timestamp come from one clock but are rounded apart.
        return newest > lastDispatched + 0.001 && uptime - newest < Self.staleAfter
    }
}

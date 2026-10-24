import AppKit

/// The input event being dispatched now: the one source the key router, the menu key gate, the
/// action signposts' input age and the key-down checks read.
///
/// `CmuxApplication.sendEvent` dispatches each event inside ``dispatching(_:_:)``, and so does a
/// key the app routes itself outside `sendEvent` (`debug.key`, a held key replayed: the key
/// router's `dispatchingSynthetic`). Nested dispatches (a synthetic event sent from inside another
/// dispatch, a menu or modal run loop) see the innermost event. `NSApp.currentEvent` is never read:
/// it is the last event AppKit dequeued, not the one given to `sendEvent`, and it keeps that event
/// after its dispatch ends, so a socket run later would report an old key press.
@MainActor
final class InputDispatchContext {
    private var stack: [NSEvent] = []

    /// The innermost event being dispatched, nil between dispatches.
    var event: NSEvent? { stack.last }

    /// Whether the innermost event being dispatched is a key-down.
    var isKeyDown: Bool { stack.last?.type == .keyDown }

    /// Runs `body` with `event` as the event being dispatched.
    func dispatching<T>(_ event: NSEvent, _ body: () throws -> T) rethrows -> T {
        stack.append(event)
        defer { stack.removeLast() }
        return try body()
    }
}

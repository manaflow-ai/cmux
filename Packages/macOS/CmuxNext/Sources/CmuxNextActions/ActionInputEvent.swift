public import Foundation

/// An OS input event as an action run reads it: whether it is a key or a click, and when it
/// happened. Chromium's `ui::Event` carries the same two facts over its platform event
/// (ui/events/event.h: `type()`, `time_stamp()`), so the registry, which builds without a UI
/// framework, never names `NSEvent`. AppKit's `NSEvent` conforms in CmuxNextActionsAppKit; a
/// reader that needs more of the event (its keys, its repeat flag) casts it to `NSEvent` there.
public nonisolated protocol ActionInputEvent: AnyObject {
    /// A key or a click; nil for any other event (a scroll, a modifier change).
    var actionInputKind: ActionInputKind? { get }
    /// When the event happened, in seconds on `ProcessInfo.systemUptime`'s clock.
    var timestamp: TimeInterval { get }
}

/// The input a person's action run answers.
public nonisolated enum ActionInputKind: Sendable, Hashable {
    /// A key-down or key-up.
    case key
    /// A mouse button down or up (left, right or other).
    case pointer
}

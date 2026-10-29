public import AppKit

// The event an action answers (plans/cmux-next/chrome-parity/p04-input.md "EVENT IDENTITY"):
// what handlers read instead of `NSApp.currentEvent`, which keeps the last dequeued event after its dispatch,
// so a socket or CLI run would read an old click or key press as its own.
@MainActor
extension InputEventTap {
    /// The input event a handler running now answers, nil when no input caused it (a CLI, socket or
    /// script run between dispatches, a control's accessibility press):
    /// - the event a menu or control's own tracking loop chose the action with (a menu item's mouse-up
    ///   or Return, Option pressed while the menu was open), which AppKit dequeued without dispatching,
    ///   read only while a dispatch or a menu's action send runs (``InputActionEventGate``);
    /// - else the event the app dispatches now (``dispatchedEvent``).
    ///
    /// Chrome reads the tracking event the same way: `ui/base/cocoa/menu_controller.mm` `itemSelected:` takes
    /// its event flags from `[NSApp currentEvent]` and hands them to `MenuModel::ActivatedAt(index, event_flags)`.
    public var actionEvent: NSEvent? {
        actionGate.actionEvent(dispatched: dispatchedEvent(), tracking: currentEvent())
    }

    /// `NSApplication.sendEvent` begins dispatching `event`, whatever its type: no action reads it, or an
    /// older event, as a tracking event after this. The application object calls it first in `sendEvent`.
    public func sendEventBegan(_ event: NSEvent) {
        actionGate.sendBegan(event.timestamp)
    }

    /// `NSApplication.sendEvent` returns. When the outermost one returns, what its tracking loops dequeued
    /// (AppKit's current event now) is no action's event any more. The application object calls it last in
    /// `sendEvent`, on every path.
    public func sendEventEnded() {
        actionGate.sendEnded(current: actionGate.sendDepth == 1 ? currentEvent()?.timestamp : nil)
    }

    /// A menu item's action is sent now (`NSApplication.sendAction(_:to:from:)` from an `NSMenuItem`): the one time
    /// outside a dispatch a menu's tracking event answers an action, since the menu bar tracks a mouse choice inside
    /// `nextEvent`, not `sendEvent`. The application object calls it around each such send.
    public func menuActionBegan() {
        actionGate.menuAction(began: true, current: nil)
    }

    /// The menu item's action send returned (``menuActionBegan()``). When the outermost returns, its tracking event
    /// (AppKit's current event now) is no action's event any more.
    public func menuActionEnded() {
        actionGate.menuAction(began: false, current: actionGate.menuActions == 1 ? currentEvent()?.timestamp : nil)
    }
}

/// When AppKit's current event is the event an action answers (``InputEventTap/actionEvent``).
///
/// AppKit's current event is the last event it dequeued. A tracking loop (a context menu inside its right-click's
/// dispatch, a button's `trackMouse` inside its mouse-down's, the menu bar's) dequeues events itself without
/// dispatching them, so the action it sends reads its choosing event there. After the loop ends that event stays
/// current until the next dispatch, and a CLI or socket run must not read it. So the current event counts only
/// - while a dispatch or a menu's action send runs, and
/// - when it is newer than ``floor``: every event `sendEvent` dispatched, whatever its type (an app-defined or a
///   mouse-entered event too), and the current event when each outermost dispatch or menu action send ended.
public struct InputActionEventGate {
    /// The newest event time no action reads as its tracking event; -infinity before the first dispatch.
    public private(set) var floor: TimeInterval = -.infinity
    /// `sendEvent` dispatches running now (nested ones add one each).
    public private(set) var sendDepth = 0
    /// Menu action sends running now.
    public private(set) var menuActions = 0

    /// A gate before any dispatch.
    public init() {}

    /// A dispatch of an event stamped `timestamp` begins.
    public mutating func sendBegan(_ timestamp: TimeInterval) {
        floor = max(floor, timestamp)
        sendDepth += 1
    }

    /// A dispatch ends; `current` is AppKit's current event's time when it was the outermost (nil otherwise).
    public mutating func sendEnded(current: TimeInterval?) {
        sendDepth = max(0, sendDepth - 1)
        if let current { floor = max(floor, current) }
    }

    /// A menu's action send begins or ends; `current` is AppKit's current event's time when the outermost ends.
    public mutating func menuAction(began: Bool, current: TimeInterval?) {
        menuActions = began ? menuActions + 1 : max(0, menuActions - 1)
        if let current { floor = max(floor, current) }
    }

    /// The event an action running now answers.
    ///
    /// - Parameters:
    ///   - dispatched: The event the app dispatches now, nil between dispatches.
    ///   - tracking: AppKit's current event.
    /// - Returns: `tracking` when a dispatch or a menu's action send runs and it is newer than ``floor`` and
    ///   `dispatched`; else `dispatched` (nil between dispatches).
    public func actionEvent(dispatched: NSEvent?, tracking: NSEvent?) -> NSEvent? {
        guard let tracking, tracking !== dispatched, dispatched != nil || menuActions > 0,
              tracking.timestamp > max(floor, dispatched?.timestamp ?? -.infinity)
        else { return dispatched }
        return tracking
    }
}

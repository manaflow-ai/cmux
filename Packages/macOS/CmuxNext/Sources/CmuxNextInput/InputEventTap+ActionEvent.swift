public import AppKit
public import CmuxNextInputCore

// The event an action answers (p04-input-067, plans/cmux-next/chrome-parity/p04-input.md "EVENT IDENTITY"):
// what handlers read instead of `NSApp.currentEvent`, which keeps the last dequeued event after its dispatch,
// so a socket or CLI run would read an old click or key press as its own.
@MainActor
extension InputEventTap {
    /// The input event a handler running now answers, nil when no input caused it (a CLI, socket or
    /// script run between dispatches):
    /// - the event a menu or control's own tracking loop chose the action with (a menu item's mouse-up
    ///   or Return, Option pressed while the menu was open), which AppKit dequeued without dispatching;
    /// - else the event the app dispatches now (``dispatchedEvent``).
    ///
    /// Chrome reads the tracking event the same way: `ui/base/cocoa/menu_controller.mm` `itemSelected:` takes
    /// its event flags from `[NSApp currentEvent]` and hands them to `MenuModel::ActivatedAt(index, event_flags)`.
    public var actionEvent: NSEvent? {
        let tracking = NSApplication.shared.currentEvent  // current-event: target-action
        return Self.actionEvent(dispatched: dispatchedEvent(), lastDispatched: lastDispatched, tracking: tracking)
    }

    /// The target-action rule of ``actionEvent``: `tracking` (AppKit's current event) counts only when it is
    /// newer than every event the app dispatched, so a tracking loop dequeued it and no dispatch did. An
    /// event the app dispatched stays the current event after its dispatch ends; it is never read again.
    ///
    /// - Parameters:
    ///   - dispatched: The event the app dispatches now, nil between dispatches.
    ///   - lastDispatched: The tap's last dispatched event, nil before the first.
    ///   - tracking: AppKit's current event.
    /// - Returns: The event the action answers, nil for none.
    public static func actionEvent(dispatched: NSEvent?, lastDispatched: InputEventRecord?, tracking: NSEvent?) -> NSEvent? {
        guard let tracking, tracking !== dispatched else { return dispatched }
        let floor = max(lastDispatched?.timestamp ?? -.infinity, dispatched?.timestamp ?? -.infinity)
        return tracking.timestamp > floor ? tracking : dispatched
    }
}

public import AppKit
public import CmuxNextInputCore

// The event identity rules of p04-input section 3 (DC7) for code outside a dispatch's own handler:
// read the event a handler was given, the tap's ``InputEventTap/lastDispatched`` record, or, in a
// target-action handler, the event a tracking loop dequeued (``InputEventTap/trackedEvent(current:)``).
// AppKit's current event is never read on its own: it keeps the last event after its dispatch ends,
// so a socket, CLI or accessibility run would read an old click or key.
@MainActor
extension InputEventTap {
    /// The event a tracking loop run inside the current dispatch dequeued itself: the mouse-up or key
    /// that chose a menu item in the menu's loop, a control's or a text view's mouse-up. Those loops
    /// take their events with `nextEvent(matching:)`, so `sendEvent` never dispatches them and
    /// ``lastDispatched`` is still the event that started the loop. Nil when AppKit's current event is
    /// no newer than ``lastDispatched``: an event already dispatched, as in a socket, CLI or
    /// accessibility run.
    ///
    /// Chrome reads the menu's own event for a bookmark menu item's disposition
    /// (`ui::WindowOpenDispositionFromNSEvent([NSApp currentEvent])` in
    /// chrome/browser/ui/cocoa/bookmarks/bookmark_menu_cocoa_controller.mm); this is that read, with
    /// the stale event filtered out.
    ///
    /// - Parameter current: AppKit's current event (tests pass their own).
    /// - Returns: `current` when it is newer than the last dispatched event, else nil.
    public func trackedEvent(current: NSEvent? = NSApp?.currentEvent) -> NSEvent? {
        Self.event(current, newerThan: lastDispatched)
    }

    /// `event` when it is newer than `last` (or nothing was dispatched yet), else nil.
    public static func event(_ event: NSEvent?, newerThan last: InputEventRecord?) -> NSEvent? {
        guard let event else { return nil }
        guard let last else { return event }
        return event.timestamp > last.timestamp ? event : nil
    }

    /// Whether `event` is the last event the app dispatched (``lastDispatched``): the press or key
    /// whose dispatch runs now, or, between dispatches, the one before.
    public func isLastDispatched(_ event: NSEvent) -> Bool {
        guard let last = lastDispatched else { return false }
        return last.timestamp == event.timestamp && last.type == InputEventType(event.type)
    }
}

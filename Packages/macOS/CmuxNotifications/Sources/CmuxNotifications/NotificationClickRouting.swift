/// Performs a notification click action's side effect (currently only
/// reveal-in-Finder). Kept app-side because it touches `NSWorkspace` and the
/// filesystem; the coordinator only dispatches the value-typed action and marks
/// the notification read when the side effect reports success.
@MainActor
public protocol NotificationClickRouting: AnyObject {
    /// Performs the click action; returns whether it succeeded. Mirrors
    /// `performTerminalNotificationClickAction`.
    func perform(_ action: NotificationNavClickAction) -> Bool
}

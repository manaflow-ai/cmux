/// When a notification's attention clears on its own
/// (`notifications.dismissal`). The dismiss verbs always clear it.
public nonisolated enum NotificationDismissal: String, Hashable, Sendable, CaseIterable {
    /// The pane is focused (in the key window, app active), clicked, typed in, or opened.
    case focus
    /// The user types into the pane (default), or opens the notification.
    case keystroke
    /// The user clicks in the pane or types into it, or opens the notification.
    case click
    /// Only opening the notification (jump, banner click) or a dismiss verb.
    case explicit
    /// After `timeoutSeconds`, or when opened or dismissed.
    case timeout
    /// Only a dismiss verb (Mark Read, Mark All Read, CLI clear).
    case never
}

/// When a macOS notification banner is posted (`notifications.desktop`).
public nonisolated enum DesktopNotificationMode: String, Hashable, Sendable, CaseIterable {
    /// Unless the notifying pane is the focused pane of the key window
    /// while cmux is active (default).
    case unlessFocused
    case always
    /// Only while cmux is not the active app.
    case whenInactive
    case never
}

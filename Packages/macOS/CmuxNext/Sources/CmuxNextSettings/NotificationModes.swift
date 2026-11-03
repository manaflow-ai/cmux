/// When a notification's attention clears on its own
/// (`notifications.dismissal`). The dismiss verbs always clear it.
public nonisolated enum NotificationDismissal: String, Hashable, Sendable, CaseIterable {
    /// The pane is selected (focused in the key window, app active, including by entering its
    /// workspace), clicked, typed in, or opened (default, as in cmux classic).
    case focus
    /// The user types into the pane, or opens the notification.
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

/// Whether the Dock icon bounces when a notification alerts while cmux is not
/// the active app (`notifications.dockBounce`).
public nonisolated enum DockBounceMode: String, Hashable, Sendable, CaseIterable {
    case off
    /// One bounce (default).
    case once
    /// Bounces until the user switches to cmux.
    case untilActive
}

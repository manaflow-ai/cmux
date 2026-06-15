/// A notification click action the coordinator can dispatch without knowing
/// how it is performed. The single case mirrors the app-target
/// `TerminalNotificationClickAction`; the coordinator forwards it to
/// ``NotificationClickRouting`` and never performs the side effect itself.
public enum NotificationNavClickAction: Sendable, Equatable {
    /// Reveal the file at `path` in Finder (selecting it, or opening its
    /// containing directory). Mirrors the app-target reveal-in-Finder action.
    case revealInFinder(path: String)
}

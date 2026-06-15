/// A notification click action the coordinator can dispatch without knowing
/// how it is performed. The single case mirrors the app-target
/// `TerminalNotificationClickAction`; the coordinator forwards it to
/// ``NotificationClickRouting`` and never performs the side effect itself.
public enum NotificationNavClickAction: Sendable, Equatable {
    case revealInFinder(path: String)
}

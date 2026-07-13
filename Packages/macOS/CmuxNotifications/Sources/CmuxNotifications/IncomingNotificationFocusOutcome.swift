/// Describes how an incoming-notification focus request was handled.
public enum IncomingNotificationFocusOutcome: Sendable, Equatable {
    /// No focus mutation was requested because policy did not allow it.
    case ignored
    /// The notification's owning workspace and surface were focused.
    case focusedTarget
    /// The target could not be focused, so the app's preferred window was activated instead.
    case activatedFallback
    /// Neither the target nor a fallback application window could be focused.
    case unavailable

    /// Whether native desktop delivery should be replaced by the focused target.
    public var suppressesDesktopDelivery: Bool {
        self == .focusedTarget
    }
}

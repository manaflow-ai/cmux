/// Where a sign-in's auth callback came from.
public enum SignInCallbackDelivery: String, Sendable, CaseIterable {
    /// The in-app sign-in window returned it.
    case signInWindow = "sign_in_window"
    /// The system delivered it from another app, usually the default browser
    /// after the window handed the sign-in off.
    case external
    /// The embedded browser's after-sign-in handoff.
    case embeddedBrowser = "embedded_browser"
}

/// Identifies why a navigation was submitted to the profile runtime.
public enum BrowserWebExtensionNavigationReason: String, Codable, Equatable, Sendable {
    /// The browser panel is starting its first navigation.
    case initial

    /// Saved browser state is being restored.
    case restore

    /// A discarded or terminated web view is being recovered.
    case recovery

    /// A browser panel changed profiles and is restoring its page.
    case profileSwitch

    /// The user explicitly requested the navigation.
    case userInitiated

    /// A hidden browser web view is preloading a page.
    case prewarm
}

/// The destination a blocked or allowed insecure-HTTP navigation resolves to
/// once the user's choice (or a one-time bypass) is applied.
///
/// Drives ``BrowserNavigationIntentCoordinator`` and the app-side insecure-HTTP
/// alert: `.currentTab` reloads the active web view, `.newTab` opens a sibling
/// browser surface.
public enum BrowserInsecureHTTPNavigationIntent: Sendable, Equatable {
    /// Resolve the navigation in the current tab's web view.
    case currentTab
    /// Resolve the navigation by opening a new sibling browser surface.
    case newTab
}

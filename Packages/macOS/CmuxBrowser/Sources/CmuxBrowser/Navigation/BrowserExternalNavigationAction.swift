public import Foundation

/// The decision for a URL that the embedded web view cannot itself navigate to.
///
/// Produced by ``BrowserExternalNavigationResolver`` when a navigation must be
/// routed away from the embedded web view: either loaded as an extracted
/// `http(s)` fallback URL (Android `intent:` deeplinks carry one) or handed to
/// macOS so the owning native app can open the deeplink scheme.
public enum BrowserExternalNavigationAction: Equatable, Sendable {
    /// Load the extracted `http(s)` fallback URL in the embedded web view
    /// instead of routing externally. Carried by `intent:` deeplinks via the
    /// `S.browser_fallback_url=` component.
    case browserFallback(URL)

    /// Hand the URL to macOS so the owning native app opens the deeplink
    /// (for example `discord://`, `slack://`, `zoommtg://`, `mailto:`).
    case promptToOpenApp(URL)
}

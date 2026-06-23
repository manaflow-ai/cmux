public import Foundation

/// Decides whether a URL must leave the embedded web view, and how.
///
/// The embedded web view can only display a fixed set of navigation schemes
/// (`http`, `https`, `file`, `about`, `data`, `blob`, `javascript`,
/// `applewebdata`, and the in-app `cmux-diff-viewer` scheme). Any other scheme
/// (`discord://`, `slack://`, `zoommtg://`, `mailto:`, `vscode:`, an Android
/// `intent:` deeplink, etc.) cannot be loaded in WebKit and must be routed
/// elsewhere: either to an extracted `http(s)` fallback URL or handed to macOS
/// so the owning native app can open it.
///
/// This is pure Foundation URL logic with no UI or WebKit dependency, so the
/// AppKit/WebKit consumers (the navigation-policy delegates that present the
/// open-in-app alert and load the fallback request) hold a resolver and act on
/// its ``BrowserExternalNavigationAction`` result. The embedded scheme set is
/// owned state seeded by ``init(embeddedNavigationSchemes:)`` (defaulting to the
/// schemes WebKit can display), not a free-standing constant.
public struct BrowserExternalNavigationResolver: Sendable {
    /// The schemes the embedded web view can navigate to directly. A URL whose
    /// scheme is outside this set is a candidate for external routing.
    private let embeddedNavigationSchemes: Set<String>

    /// Creates a resolver.
    ///
    /// - Parameter embeddedNavigationSchemes: The lowercased schemes the
    ///   embedded web view can display itself. Defaults to the WebKit-navigable
    ///   set plus the in-app `cmux-diff-viewer` scheme.
    public init(
        embeddedNavigationSchemes: Set<String> = [
            "about",
            "applewebdata",
            "blob",
            "cmux-diff-viewer",
            "data",
            "file",
            "http",
            "https",
            "javascript",
        ]
    ) {
        self.embeddedNavigationSchemes = embeddedNavigationSchemes
    }

    /// Returns whether a URL's scheme is one the embedded web view cannot
    /// display and therefore should be opened in an external application.
    ///
    /// A URL with no scheme (or an empty scheme) is never external.
    public func shouldOpenURLExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !embeddedNavigationSchemes.contains(scheme)
    }

    /// Returns whether a URL needs to be routed away from the embedded web view,
    /// i.e. whether ``externalNavigationAction(for:)`` produces an action.
    public func shouldRouteExternalNavigation(_ url: URL) -> Bool {
        return externalNavigationAction(for: url) != nil
    }

    /// Extracts the `http(s)` `S.browser_fallback_url=` value from an Android
    /// `intent:` deeplink, or `nil` when the URL is not an `intent:` URL or
    /// carries no valid `http(s)` fallback.
    public func intentFallbackURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "intent" else { return nil }
        guard let intentMarker = url.absoluteString.range(of: "#Intent;") else { return nil }

        let fallbackPrefix = "S.browser_fallback_url="
        let intentBody = url.absoluteString[intentMarker.upperBound...]
        for component in intentBody.split(separator: ";", omittingEmptySubsequences: false) {
            if component == "end" { break }
            guard component.hasPrefix(fallbackPrefix) else { continue }

            let rawFallbackURL = String(component.dropFirst(fallbackPrefix.count))
            guard !rawFallbackURL.isEmpty else { return nil }

            let decodedFallbackURL = rawFallbackURL.removingPercentEncoding ?? rawFallbackURL
            guard let fallbackURL = URL(string: decodedFallbackURL),
                  let fallbackScheme = fallbackURL.scheme?.lowercased(),
                  fallbackScheme == "http" || fallbackScheme == "https" else {
                return nil
            }
            return fallbackURL
        }

        return nil
    }

    /// Returns the external-navigation decision for a URL, or `nil` when the URL
    /// can stay in the embedded web view.
    ///
    /// An `intent:` deeplink with an `http(s)` fallback resolves to
    /// ``BrowserExternalNavigationAction/browserFallback(_:)``; any other
    /// non-embeddable scheme resolves to
    /// ``BrowserExternalNavigationAction/promptToOpenApp(_:)``.
    public func externalNavigationAction(for url: URL) -> BrowserExternalNavigationAction? {
        if let fallbackURL = intentFallbackURL(for: url) {
            return .browserFallback(fallbackURL)
        }
        guard shouldOpenURLExternally(url) else { return nil }
        return .promptToOpenApp(url)
    }
}

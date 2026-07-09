public import Foundation

/// The hand-off a browser surface should perform when a navigation targets a
/// URL that does not belong in the embedded WebKit view.
///
/// External-navigation classification is pure: it inspects only the URL's scheme
/// and, for Android `intent://` URLs, the embedded `S.browser_fallback_url`,
/// never any live WebKit, window, or pasteboard state. The owning app surface
/// resolves the action with ``resolve(for:)`` and performs the actual
/// presentation and hand-off (NSAlert, NSWorkspace, pasteboard), which stay
/// app-side.
public enum BrowserExternalNavigationAction: Sendable, Equatable {
    /// Load `url` inside the embedded WebKit view: an `http`/`https` fallback URL
    /// extracted from an Android `intent://` URL.
    case browserFallback(URL)

    /// Prompt the user to open `url` in its owning native app.
    case promptToOpenApp(URL)

    /// Schemes WebKit renders inline; every other scheme routes out to macOS.
    private static let embeddedNavigationSchemes: Set<String> = [
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

    /// Whether `url`'s scheme is one WebKit cannot render inline, so the URL
    /// should be handed to the owning native app rather than loaded in place.
    public static func shouldOpenURLExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !embeddedNavigationSchemes.contains(scheme)
    }

    /// Whether `url` warrants any external hand-off (an `intent://` fallback load
    /// or a prompt to open the owning app).
    public static func shouldRoute(_ url: URL) -> Bool {
        return resolve(for: url) != nil
    }

    /// The `http`/`https` `browser_fallback_url` embedded in an Android
    /// `intent://` URL, or `nil` when there is none or it is not web-safe.
    public static func intentFallbackURL(for url: URL) -> URL? {
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

    /// The external-navigation action for `url`, or `nil` when the URL should
    /// stay in the embedded WebKit view.
    public static func resolve(for url: URL) -> BrowserExternalNavigationAction? {
        if let fallbackURL = intentFallbackURL(for: url) {
            return .browserFallback(fallbackURL)
        }
        guard shouldOpenURLExternally(url) else { return nil }
        return .promptToOpenApp(url)
    }
}

import Foundation

private let browserEmbeddedNavigationSchemes: Set<String> = [
    "about",
    "applewebdata",
    "blob",
    "cmux-diff-viewer",
    "data",
    "file",
    "http",
    "https",
    "javascript",
    "webkit-extension",
]

extension URL {
    var browserShouldOpenExternally: Bool {
        guard let scheme = scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !browserEmbeddedNavigationSchemes.contains(scheme)
    }

    var browserShouldRouteExternalNavigation: Bool {
        browserExternalNavigationAction != nil
    }

    var browserIntentFallbackURL: URL? {
        guard scheme?.lowercased() == "intent" else { return nil }
        guard let intentMarker = absoluteString.range(of: "#Intent;") else { return nil }

        let fallbackPrefix = "S.browser_fallback_url="
        let intentBody = absoluteString[intentMarker.upperBound...]
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

    var browserExternalNavigationAction: BrowserExternalNavigationAction? {
        if let fallbackURL = browserIntentFallbackURL {
            return .browserFallback(fallbackURL)
        }
        guard browserShouldOpenExternally else { return nil }
        return .promptToOpenApp(self)
    }
}

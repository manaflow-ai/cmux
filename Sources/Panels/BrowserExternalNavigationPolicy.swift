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

func browserShouldOpenURLExternally(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
    return !browserEmbeddedNavigationSchemes.contains(scheme)
}

enum BrowserExternalNavigationAction: Equatable {
    case browserFallback(URL)
    case promptToOpenApp(URL)
}

enum BrowserExternalNavigationHandlingResult: Equatable {
    case notHandled
    case browserFallback
    case externalPrompt
}

func browserShouldRouteExternalNavigation(_ url: URL) -> Bool {
    return browserExternalNavigationAction(for: url) != nil
}

func browserIntentFallbackURL(for url: URL) -> URL? {
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

func browserExternalNavigationAction(for url: URL) -> BrowserExternalNavigationAction? {
    if let fallbackURL = browserIntentFallbackURL(for: url) {
        return .browserFallback(fallbackURL)
    }
    guard browserShouldOpenURLExternally(url) else { return nil }
    return .promptToOpenApp(url)
}

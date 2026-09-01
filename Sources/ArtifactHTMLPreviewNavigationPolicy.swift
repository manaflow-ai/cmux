import Foundation

/// Restricts artifact previews to their wrapper document and inert `srcdoc` frame.
struct ArtifactHTMLPreviewNavigationPolicy {
    let documentURL: URL

    func allowsNavigation(to url: URL?, targetIsMainFrame: Bool?) -> Bool {
        guard let url else { return false }
        switch targetIsMainFrame {
        case true:
            return url == documentURL
                || Self.withoutFragment(url) == Self.withoutFragment(documentURL)
        case false:
            let base = Self.withoutFragment(url).absoluteString
            return base == "about:srcdoc" || base == "about:blank"
        case nil:
            return false
        }
    }

    private static func withoutFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return components.url ?? url
    }
}

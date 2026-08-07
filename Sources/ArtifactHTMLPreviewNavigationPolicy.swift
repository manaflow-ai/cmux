import Foundation

/// Restricts artifact previews to their wrapper document and inert `srcdoc` frame.
struct ArtifactHTMLPreviewNavigationPolicy {
    let documentURL: URL

    func allowsNavigation(to url: URL?, targetIsMainFrame: Bool?) -> Bool {
        guard let url else { return false }
        switch targetIsMainFrame {
        case true:
            return url == documentURL
        case false:
            return url.absoluteString == "about:srcdoc" || url.absoluteString == "about:blank"
        case nil:
            return false
        }
    }
}

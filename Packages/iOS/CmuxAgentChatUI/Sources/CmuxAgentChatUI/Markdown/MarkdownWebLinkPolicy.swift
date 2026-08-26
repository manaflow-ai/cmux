import Foundation

/// Classifies navigation targets inside the iOS markdown web renderer.
///
/// The shell is loaded with `loadHTMLString(_:baseURL: nil)`, so heading
/// anchors resolve as `about:blank#fragment`; those must stay inside the
/// WebView while every other activated link leaves the app through the
/// system opener. Pure so it can be unit-tested without WebKit.
enum MarkdownWebLinkPolicy {
    /// Same-document fragment navigation (heading anchors) that the WebView
    /// should perform natively.
    static func isInPageFragment(_ url: URL) -> Bool {
        guard url.fragment != nil else { return false }
        if url.scheme == nil || url.scheme == "about" {
            return (url.host ?? "").isEmpty
        }
        return false
    }

    /// Whether the system opener may handle an activated link. Anything the
    /// phone can't represent (relative paths against about:blank) is dropped.
    static func externalURL(for url: URL) -> URL? {
        if isInPageFragment(url) { return nil }
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty, scheme != "about" else {
            return nil
        }
        return url
    }
}

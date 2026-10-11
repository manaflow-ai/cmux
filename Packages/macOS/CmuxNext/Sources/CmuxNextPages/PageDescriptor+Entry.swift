import Foundation

extension PageDescriptor {
    /// Whether `url` is this page's own document, the one its main frame may show: its origin,
    /// the root path or the entry file, no query (a fragment is a route inside the document).
    /// Any other path on the origin (a link relative to the page, `..`, `//host`) would replace
    /// the page and drop its state.
    nonisolated func isEntryDocument(_ url: URL) -> Bool {
        guard owns(url), url.query == nil else { return false }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return path.isEmpty || path == "/" || path == "/" + entry
    }
}

import Foundation

extension AgentPaneSource {
    /// Whether `url` is the page document itself, the only one the pane's main frame shows: the
    /// bundled page (``isTrusted(_:)`` already names its one path), or the dev server's root path
    /// on its exact origin (any query or fragment). A link relative to the page resolves to its
    /// origin, so without the path rule it would replace the page. A query is allowed here and not
    /// on the page host (PageDescriptor.isEntryDocument): a dev-server page may carry one, a bundled page never does.
    nonisolated func isPageDocument(_ url: URL) -> Bool {
        guard isTrusted(url) else { return false }
        guard case .devServer(let root) = self else { return true }
        func path(_ url: URL) -> String {
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
            return path.isEmpty ? "/" : path
        }
        return path(url) == path(root)
    }
}

extension AgentPaneNavigation {
    /// Opens a clicked link outside the pane: only an http(s) URL with a host and no user name or
    /// password, and only by spending a real user gesture in the pane (``AgentPaneUserGestures``,
    /// which page script cannot record), so WebKit's link-activated flag is never the only proof.
    /// True when it opened.
    @MainActor static func openOutside(_ url: URL, gestures: AgentPaneUserGestures, open: (URL) -> Void) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil, url.host?.isEmpty == false,
              gestures.consume() else { return false }
        open(url)
        return true
    }
}

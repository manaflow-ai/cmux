/// Why the page host could not serve a request.
public enum BrowserPageError: Error, Hashable, Sendable {
    /// No browser tab with that id in this host's tree.
    case tabNotFound
    /// The page owner failed (load refused, engine gone).
    case failed(String)
}

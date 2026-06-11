public import Foundation

/// The outcome of `browser.url.get`.
public enum ControlBrowserURLResolution: Sendable, Equatable {
    /// The workspace or browser panel did not resolve (legacy `not_found` /
    /// "Surface not found or not a browser").
    case notFoundOrNotBrowser
    /// The resolved panel's current URL (empty string when none, as legacy).
    case ok(workspaceID: UUID, url: String)
}

public import Foundation

/// The outcome of `browser.url.get`. The witness resolves the workspace and
/// browser panel; a never-navigated surface reports `about:blank` (matching JS
/// `location.href`) rather than an empty string.
public enum ControlBrowserURLResolution: Sendable, Equatable {
    /// The surface did not resolve to a browser of the workspace
    /// (`not_found` / "Surface not found or not a browser",
    /// data `{"surface_id": …}`).
    case notFound
    /// Resolved: the owning workspace and the current URL string.
    case resolved(workspaceID: UUID, url: String)
}

public import Foundation

/// The outcome of `browser.navigate` and the simple nav actions: the legacy
/// bodies returned a single default `not_found` when workspace or panel did
/// not resolve, or the identity payload after acting.
public enum ControlBrowserNavResolution: Sendable, Equatable {
    /// The workspace or browser panel did not resolve (legacy `not_found` /
    /// "Surface not found or not a browser").
    case notFoundOrNotBrowser
    /// The action ran; carries the ids the payload needs.
    case ok(workspaceID: UUID, windowID: UUID?)
}

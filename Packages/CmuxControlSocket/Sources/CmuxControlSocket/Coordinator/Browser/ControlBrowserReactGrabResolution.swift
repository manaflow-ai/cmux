public import Foundation

/// The outcome of `browser.react_grab.toggle`: the legacy body returned a
/// single default `not_found` ("No browser surface to toggle React Grab on")
/// when the workspace or toggle target did not resolve.
public enum ControlBrowserReactGrabResolution: Sendable, Equatable {
    /// No workspace, or `toggleReactGrab` found no browser (legacy `not_found`).
    case notFound
    /// React Grab toggled on the acted browser.
    case toggled(workspaceID: UUID, surfaceID: UUID, windowID: UUID?)
}

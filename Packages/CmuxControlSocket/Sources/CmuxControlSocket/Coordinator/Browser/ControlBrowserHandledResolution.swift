public import Foundation

/// The outcome of a focused-browser action: the legacy bodies returned a
/// single default `not_found` ("No browser surface found") when the workspace
/// or target browser did not resolve, or the identity payload plus the
/// panel-reported `handled` flag.
public enum ControlBrowserHandledResolution: Sendable, Equatable {
    /// No workspace or no target browser (legacy `not_found`).
    case notFound
    /// The action ran on the resolved browser.
    case acted(workspaceID: UUID, surfaceID: UUID, windowID: UUID?, handled: Bool)
}

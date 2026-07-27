public import Foundation

/// The app-bundle-resolved localized strings for `surface.respawn`.
///
/// Lifted from the legacy `v2SurfaceRespawn` body's `String(localized:)` calls.
/// They MUST resolve in the app conformance (app bundle), not the package: inside
/// the package `String(localized:)` binds to the package bundle, which lacks the
/// keys and silently drops the Japanese translation (a wire change). The app
/// resolves each with the identical key + defaultValue and passes them through.
public struct ControlSurfaceRespawnStrings: Sendable, Equatable {
    /// `rpc.v2.surface.respawn.invalidFocus` — "Missing or invalid focus".
    public let invalidFocus: String
    /// `rpc.v2.surface.respawn.failed` — "Failed to respawn surface".
    public let failed: String
    /// `rpc.v2.surface.respawn.surfaceNotFoundForId` — "Surface not found for the
    /// given surface_id".
    public let surfaceNotFoundForID: String
    /// `rpc.v2.surface.respawn.tabManagerUnavailable` — "Unable to access the
    /// target workspace".
    public let tabManagerUnavailable: String
    /// `rpc.v2.surface.respawn.workspaceNotFound` — "Workspace not found".
    public let workspaceNotFound: String
    /// `rpc.v2.surface.respawn.noFocusedSurface` — "No focused surface".
    public let noFocusedSurface: String
    /// `rpc.v2.surface.respawn.surfaceNotTerminal` — "Surface is not a terminal".
    public let surfaceNotTerminal: String

    /// Creates the respawn strings.
    public init(
        invalidFocus: String,
        failed: String,
        surfaceNotFoundForID: String,
        tabManagerUnavailable: String,
        workspaceNotFound: String,
        noFocusedSurface: String,
        surfaceNotTerminal: String
    ) {
        self.invalidFocus = invalidFocus
        self.failed = failed
        self.surfaceNotFoundForID = surfaceNotFoundForID
        self.tabManagerUnavailable = tabManagerUnavailable
        self.workspaceNotFound = workspaceNotFound
        self.noFocusedSurface = noFocusedSurface
        self.surfaceNotTerminal = surfaceNotTerminal
    }
}

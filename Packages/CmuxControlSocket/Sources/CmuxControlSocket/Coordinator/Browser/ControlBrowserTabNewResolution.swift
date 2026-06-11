public import Foundation

/// The outcome of the app-side `browser.tab.new` creation.
public enum ControlBrowserTabNewResolution: Sendable, Equatable {
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// No target pane resolved (legacy `not_found` / "Target pane not found").
    case paneNotFound
    /// Browser creation failed (legacy `internal_error` /
    /// "Failed to create browser tab").
    case createFailed
    /// The tab was created; `url` is the created panel's current URL.
    case created(workspaceID: UUID, paneID: UUID, surfaceID: UUID, url: String)
}

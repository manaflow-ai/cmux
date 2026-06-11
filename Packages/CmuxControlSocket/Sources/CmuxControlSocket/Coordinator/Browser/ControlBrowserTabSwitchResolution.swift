public import Foundation

/// The outcome of the app-side `browser.tab.switch`.
public enum ControlBrowserTabSwitchResolution: Sendable, Equatable {
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// No matching browser tab (legacy `not_found` / "Browser tab not found").
    case tabNotFound
    /// The tab was focused.
    case switched(workspaceID: UUID, surfaceID: UUID)
}

import Foundation

/// Seam through which `MarkdownLinkRouter` opens new cmux surfaces without
/// reaching `AppDelegate`/`Workspace` directly. The concrete app-side conformer
/// (`AppDelegateMarkdownPanelSurfaceRouting`) locates the workspace that owns a
/// markdown panel and creates the surface; each method returns whether the
/// owning panel was located (so the router can fall back to the system browser).
@MainActor
protocol MarkdownPanelSurfaceRouting {
    /// Open `filePath` as a markdown surface in the pane that owns `panelId`.
    /// Returns `false` when the panel can't be located in any workspace.
    func openMarkdownSurface(filePath: String, fromPanelId panelId: UUID, preferredWorkspaceId workspaceId: UUID) -> Bool
    /// Open `url` as a browser surface in the pane that owns `panelId`.
    /// Returns `false` when the panel can't be located in any workspace.
    func openBrowserSurface(url: URL, fromPanelId panelId: UUID, preferredWorkspaceId workspaceId: UUID) -> Bool
}

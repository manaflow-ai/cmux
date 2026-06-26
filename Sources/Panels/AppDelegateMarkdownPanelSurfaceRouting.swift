import Foundation

/// App-side conformer of `MarkdownPanelSurfaceRouting`. Locates the workspace
/// that currently owns a markdown panel via `AppDelegate.workspaceContainingPanel`
/// and creates the requested surface on that workspace. Stateless: every call
/// re-resolves the panel's owning workspace, so it stays correct as panels move
/// between panes/workspaces.
@MainActor
struct AppDelegateMarkdownPanelSurfaceRouting: MarkdownPanelSurfaceRouting {
    func openMarkdownSurface(filePath: String, fromPanelId panelId: UUID, preferredWorkspaceId workspaceId: UUID) -> Bool {
        guard let app = AppDelegate.shared,
              let location = app.workspaceContainingPanel(
                  panelId: panelId,
                  preferredWorkspaceId: workspaceId
              ),
              let paneId = location.workspace.paneId(forPanelId: panelId) else { return false }
        _ = location.workspace.newMarkdownSurface(
            inPane: paneId,
            filePath: filePath,
            focus: true
        )
        return true
    }

    func openBrowserSurface(url: URL, fromPanelId panelId: UUID, preferredWorkspaceId workspaceId: UUID) -> Bool {
        guard let app = AppDelegate.shared,
              let location = app.workspaceContainingPanel(
                  panelId: panelId,
                  preferredWorkspaceId: workspaceId
              ),
              let paneId = location.workspace.paneId(forPanelId: panelId) else { return false }
        _ = location.workspace.newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: true
        )
        return true
    }
}

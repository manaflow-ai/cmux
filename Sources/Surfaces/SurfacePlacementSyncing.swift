import Foundation

/// The machine-layout mutations the sync service asks a provider for. Only providers
/// with a daemon layout conform; the local machine has none.
@MainActor
protocol SurfacePlacementSyncing: AnyObject {
    /// Moves one existing tab placement into `remoteWorkspaceID`: its focused pane, after
    /// that pane's tabs. The content behind the tab is untouched.
    func moveRemoteTab(id: String, intoRemoteWorkspace remoteWorkspaceID: String) async throws -> SurfaceRemotePlacement
    /// Gives a terminal that has no placement a tab in `remoteWorkspaceID`.
    func projectTerminal(_ id: SurfaceResourceID, intoRemoteWorkspace remoteWorkspaceID: String) async throws -> SurfaceRemotePlacement
    /// Closes one tab placement. The terminal behind it keeps running, detached into the
    /// machine's pool (`spec/cli.md`: only `terminal close` kills).
    func closeRemoteTab(id: String, inRemoteWorkspace remoteWorkspaceID: String) async throws
}

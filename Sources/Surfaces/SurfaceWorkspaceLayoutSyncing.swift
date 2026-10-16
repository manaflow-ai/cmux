import CmuxSurfaceCatalogModel
import Foundation

/// A provider that can record a native workspace's split tree on its machine.
///
/// A bound Cloud workspace is re-derived from the machine's layout document whenever
/// its graph changes. A local arrangement that never reaches the machine is therefore
/// undone by the next unrelated update, so every native layout edit is written here.
@MainActor
protocol SurfaceWorkspaceLayoutSyncing: AnyObject {
    /// Converges `remoteWorkspaceID` to `desired` and returns the final planner step:
    /// ``CloudLayoutSyncStep/done`` on success, or the reason nothing (more) was written.
    func syncWorkspaceLayout(_ desired: CloudLayoutSyncTree, remoteWorkspaceID: String) async throws -> CloudLayoutSyncStep
}

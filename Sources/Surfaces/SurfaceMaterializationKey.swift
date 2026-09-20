import Foundation

/// Coalesces one remote view within its destination and pending pane generation.
struct SurfaceMaterializationKey: Hashable {
    let resource: SurfaceResourceID
    let remoteTabID: String?
    let destination: SurfaceDestination
    let workspaceID: UUID?
    let loadingPanelID: UUID?
    var machine: SurfaceMachineID { resource.machine }
}

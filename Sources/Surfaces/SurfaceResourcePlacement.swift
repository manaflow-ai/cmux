import Foundation

/// One resource in a group, with the immutable daemon placement that produced the
/// row. A terminal id is not enough when one terminal is shown by several tabs.
/// The tab id is an opaque routing key; the current catalog resolves it to fresh
/// metadata immediately before materialization.
struct SurfaceResourcePlacement: Hashable, Codable, Sendable {
    let resource: SurfaceResourceID
    let remoteWorkspaceID: String?
    let remoteTabID: String?

    init(
        resource: SurfaceResourceID,
        remoteView: SurfaceRemoteView? = nil,
        remoteWorkspaceID: String? = nil,
        remoteTabID: String? = nil
    ) {
        self.resource = resource
        self.remoteWorkspaceID = remoteView?.workspace.id ?? remoteWorkspaceID
        self.remoteTabID = remoteView?.tabID ?? remoteTabID
    }
}

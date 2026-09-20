import Foundation

/// A committed workspace and its optional starter, available before a graph refresh.
struct SurfaceWorkspaceCreationReceipt: Sendable {
    let workspace: SurfaceRemoteWorkspace
    let terminal: SurfaceResource?
    let cursor: CloudVMCursor?
}

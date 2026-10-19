import CmuxSurfaceCatalogModel
import Foundation

/// A committed workspace and its optional starter, available before a graph refresh.
public struct SurfaceWorkspaceCreationReceipt: Sendable {
    public init(
        workspace: SurfaceRemoteWorkspace,
        terminal: SurfaceResource?,
        cursor: CloudVMCursor?
    ) {
        self.workspace = workspace
        self.terminal = terminal
        self.cursor = cursor
    }

    public let workspace: SurfaceRemoteWorkspace
    public let terminal: SurfaceResource?
    public let cursor: CloudVMCursor?
}

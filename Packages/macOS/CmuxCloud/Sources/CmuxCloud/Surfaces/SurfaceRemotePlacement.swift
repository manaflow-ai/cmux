import CmuxSurfaceCatalogModel

/// The confirmed daemon tab behind a local pane. It is independent of local geometry.
public struct SurfaceRemotePlacement: Equatable, Sendable {
    public init(
        workspaceID: String,
        tabID: String,
        cursor: CloudVMCursor? = nil
    ) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.cursor = cursor
    }

    public let workspaceID: String
    public let tabID: String
    public var cursor: CloudVMCursor? = nil
}

import CmuxSurfaceCatalogModel

/// The daemon's creation receipt and the source snapshot's workspace identity.
public struct CloudTerminalLayoutCreationResult: Sendable {
    public init(
        created: CmuxTuiSnapshotParser.CreatedTerminalPath,
        workspaceID: String
    ) {
        self.created = created
        self.workspaceID = workspaceID
    }

    public let created: CmuxTuiSnapshotParser.CreatedTerminalPath
    public let workspaceID: String
}

/// The daemon's creation receipt and the source snapshot's workspace identity.
import CmuxSurfaceCatalogModel

struct CloudTerminalLayoutCreationResult: Sendable {
    let created: CmuxTuiSnapshotParser.CreatedTerminalPath
    let workspaceID: String
}

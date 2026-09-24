/// The daemon's creation receipt and the source snapshot's workspace identity.
struct CloudTerminalLayoutCreationResult: Sendable {
    let created: CmuxTuiSnapshotParser.CreatedTerminalPath
    let workspaceID: String
}

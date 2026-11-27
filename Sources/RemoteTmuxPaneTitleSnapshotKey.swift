import CmuxRemoteSession

typealias RemoteTmuxPaneTitleMetadata = CmuxRemoteSession.RemoteTmuxPaneTitleMetadata

/// Identifies one pane-rectangle snapshot so an older reply cannot overwrite a
/// newer live pane-title subscription event.
struct RemoteTmuxPaneTitleSnapshotKey: Hashable, Sendable {
    let windowId: Int
    let generation: Int
}

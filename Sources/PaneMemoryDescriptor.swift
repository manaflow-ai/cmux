import Foundation

/// Main-actor snapshot of one live pane gathered before an off-main memory scan.
/// `ttyName` is the workspace's cached shell-reported identity. Periodic scans
/// must not synchronously query libghostty because a stalled native surface
/// would otherwise block the UI every four seconds. Scoped process snapshots
/// attribute panes by `panelId` when no cached TTY is available.
struct PaneMemoryDescriptor: Sendable {
    let workspaceId: UUID
    let panelId: UUID
    let workspaceTitle: String
    let paneTitle: String
    let ttyName: String?
    let foregroundPID: Int?

    var key: PaneMemoryPaneKey { PaneMemoryPaneKey(workspaceId: workspaceId, panelId: panelId) }
}

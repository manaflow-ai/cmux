import Foundation

/// Main-actor snapshot of one live pane gathered before an off-main memory scan.
/// `ttyName` / `foregroundPID` come from libghostty (see
/// `TerminalSurface.controllingTTYName()` / `foregroundProcessID()`).
struct PaneMemoryDescriptor: Sendable {
    let workspaceId: UUID
    let panelId: UUID
    let workspaceTitle: String
    let paneTitle: String
    let ttyName: String?
    let foregroundPID: Int?

    var key: PaneMemoryPaneKey { PaneMemoryPaneKey(workspaceId: workspaceId, panelId: panelId) }
}

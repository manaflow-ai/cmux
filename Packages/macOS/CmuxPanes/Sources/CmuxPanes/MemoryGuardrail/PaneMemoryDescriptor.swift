public import Foundation

/// Main-actor snapshot of one live pane gathered before an off-main memory scan.
/// `ttyName` / `foregroundPID` come from libghostty (see
/// `TerminalSurface.controllingTTYName()` / `foregroundProcessID()`).
public struct PaneMemoryDescriptor: Sendable {
    public let workspaceId: UUID
    public let panelId: UUID
    public let workspaceTitle: String
    public let paneTitle: String
    public let ttyName: String?
    public let foregroundPID: Int?

    public init(
        workspaceId: UUID,
        panelId: UUID,
        workspaceTitle: String,
        paneTitle: String,
        ttyName: String?,
        foregroundPID: Int?
    ) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.workspaceTitle = workspaceTitle
        self.paneTitle = paneTitle
        self.ttyName = ttyName
        self.foregroundPID = foregroundPID
    }

    public var key: PaneMemoryPaneKey { PaneMemoryPaneKey(workspaceId: workspaceId, panelId: panelId) }
}

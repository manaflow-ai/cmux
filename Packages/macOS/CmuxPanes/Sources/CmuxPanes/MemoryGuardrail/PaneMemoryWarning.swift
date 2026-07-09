public import Foundation

/// The content surfaced in the dismissible warning banner.
public struct PaneMemoryWarning: Equatable, Identifiable, Sendable {
    public let workspaceId: UUID
    public let panelId: UUID
    public let workspaceTitle: String
    public let paneTitle: String
    public let memoryBytes: Int64
    public let foregroundCommand: String?

    public init(
        workspaceId: UUID,
        panelId: UUID,
        workspaceTitle: String,
        paneTitle: String,
        memoryBytes: Int64,
        foregroundCommand: String?
    ) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.workspaceTitle = workspaceTitle
        self.paneTitle = paneTitle
        self.memoryBytes = memoryBytes
        self.foregroundCommand = foregroundCommand
    }

    public var id: UUID { panelId }
    public var key: PaneMemoryPaneKey { PaneMemoryPaneKey(workspaceId: workspaceId, panelId: panelId) }
}

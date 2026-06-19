public import Foundation

/// Stable identity of a single pane (workspace + panel) for guardrail tracking.
public struct PaneMemoryPaneKey: Hashable, Sendable {
    public let workspaceId: UUID
    public let panelId: UUID

    public init(workspaceId: UUID, panelId: UUID) {
        self.workspaceId = workspaceId
        self.panelId = panelId
    }
}

import Foundation

/// Identifies the sidebar slot an attention overlay lights up. Overlays
/// are refcounted by this key so overlapping blocking decisions on the
/// same agent/panel don't clear each other's needs-input badge.
public struct AttentionTarget: Hashable, Sendable {
    public let workspaceId: UUID
    public let panelId: UUID?
    public let statusKey: String

    public init(workspaceId: UUID, panelId: UUID?, statusKey: String) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.statusKey = statusKey
    }
}

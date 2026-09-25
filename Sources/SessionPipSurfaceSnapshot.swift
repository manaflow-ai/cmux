import Foundation

struct SessionPipSurfaceSnapshot: Codable, Sendable {
    var panel: SessionPanelSnapshot
    var frame: SessionRectSnapshot
    var homeWorkspaceId: UUID
}

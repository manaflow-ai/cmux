import CoreGraphics
import Foundation

struct SidebarWorkspaceReorderPendingDrop {
    let requestId: UInt64
    let point: CGPoint
    let workspaceId: UUID?
    let sessionId: UUID?

    init(
        requestId: UInt64,
        point: CGPoint,
        workspaceId: UUID? = nil,
        sessionId: UUID? = nil
    ) {
        self.requestId = requestId
        self.point = point
        self.workspaceId = workspaceId
        self.sessionId = sessionId
    }
}

import CoreGraphics
import Foundation

struct SidebarWorkspaceReorderDropOverlayTarget: Equatable {
    let workspaceId: UUID
    let groupId: UUID?
    let isGroupHeader: Bool
    let frame: CGRect
}

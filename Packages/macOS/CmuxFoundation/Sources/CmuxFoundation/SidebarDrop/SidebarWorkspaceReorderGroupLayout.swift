import CoreGraphics
import Foundation

/// Visible bounds and neighbor data for one expanded workspace group.
struct SidebarWorkspaceReorderGroupLayout {
    let bounds: CGRect
    let anchorTarget: SidebarWorkspaceReorderDropTarget
    let nextRootTarget: SidebarWorkspaceReorderDropTarget?
}

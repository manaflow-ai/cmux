import CoreGraphics
import Foundation

/// Root-level insertion target derived from visible sidebar rows.
struct SidebarWorkspaceReorderRootTarget {
    let workspaceId: UUID?
    let edge: SidebarDropEdge
    let pointerY: CGFloat?
    let targetHeight: CGFloat?
    let indicator: SidebarDropIndicator?
    let indicatorScope: SidebarWorkspaceReorderDropIndicatorScope
}

import CoreGraphics
import Foundation

/// Row hit-test context used while resolving a workspace reorder drag.
struct SidebarWorkspaceReorderHitContext {
    let target: SidebarWorkspaceReorderDropTarget?
    let previousTarget: SidebarWorkspaceReorderDropTarget?
    let nextTarget: SidebarWorkspaceReorderDropTarget?
    let edge: SidebarDropEdge
    let pointerY: CGFloat?
    let targetHeight: CGFloat?
}

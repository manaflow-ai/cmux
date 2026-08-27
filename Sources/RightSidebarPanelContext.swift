import CmuxAppKitSupportUI
import SwiftUI

/// Inputs shared by every right-sidebar panel descriptor.
struct RightSidebarPanelContext {
    let tabManager: TabManager
    let fileExplorerStore: FileExplorerStore
    let fileExplorerState: FileExplorerState
    let sessionIndexStore: SessionIndexStore
    let sessionIndexDirectory: String?
    let titlebarHeight: CGFloat
    let windowAppearance: WindowAppearanceSnapshot
    let workspaceId: UUID?
    let onResumeSession: ((SessionEntry) -> Void)?
    let onOpenFilePreview: (String) -> Void
    let onOpenAsPane: (RightSidebarMode) -> Void
    let onOpenDiffViewer: (String) -> Void
    let onClose: () -> Void
}

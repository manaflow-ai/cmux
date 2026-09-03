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
    /// Launches an indexed session in a new split in the selected workspace.
    let onOpenSession: ((SessionEntry) -> Void)?
    let onOpenFilePreview: (String) -> Void
    let onOpenAsPane: (RightSidebarMode) -> Void
    let onOpenDiffViewer: (String, GitFileDiffSource) -> Void
    let onClose: () -> Void
}

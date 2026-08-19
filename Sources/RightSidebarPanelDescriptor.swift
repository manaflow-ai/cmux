import AppKit
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
    let onOpenDiffViewer: () -> Void
    let onClose: () -> Void
}

/// Declarative metadata and content factory for one right-sidebar panel.
struct RightSidebarPanelDescriptor: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let order: Int
    let isAvailable: () -> Bool
    let shortcutAction: KeyboardShortcutSettings.Action?
    let cliArgument: String
    let commandPaletteCommandID: String
    let paneCommandID: String?
    let paneTitle: String?
    let supportsTearOffPane: Bool
    let syncsFileExplorerRoot: Bool
    let makeContent: @MainActor (RightSidebarPanelContext) -> AnyView
}

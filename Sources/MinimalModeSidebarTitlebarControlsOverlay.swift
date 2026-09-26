import AppKit
import CmuxNotifications
import SwiftUI

struct MinimalModeSidebarTitlebarControlsOverlay: View {
    let unreadModel: SidebarUnreadModel
    let layoutModel: TitlebarControlsLayoutModel
    let leadingInset: CGFloat
    let topPadding: CGFloat
    let onToggleSidebar: () -> Void
    let onToggleNotifications: (NSView?) -> Void
    let onNewTab: () -> Void
    let onFocusHistoryBack: () -> Void
    let onFocusHistoryForward: () -> Void

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    @AppStorage(WorkspaceTitlebarSettings.showTitlebarKey)
    private var showWorkspaceTitlebar = WorkspaceTitlebarSettings.defaultShowTitlebar

    private var hasHiddenTitlebar: Bool {
        WorkspaceTitlebarSettings.isHidden(
            showTitlebar: showWorkspaceTitlebar,
            presentationMode: workspacePresentationMode
        )
    }

    var body: some View {
        if hasHiddenTitlebar {
            HiddenTitlebarSidebarControlsView(
                unreadModel: unreadModel,
                layoutModel: layoutModel,
                onToggleSidebar: onToggleSidebar,
                onToggleNotifications: onToggleNotifications,
                onNewTab: onNewTab,
                onFocusHistoryBack: onFocusHistoryBack,
                onFocusHistoryForward: onFocusHistoryForward
            )
            .padding(.leading, leadingInset)
            .padding(.top, topPadding)
        }
    }
}

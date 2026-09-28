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

    @WorkspaceTitlebarConfiguration private var titlebarSettings

    var body: some View {
        if titlebarSettings.isHidden {
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

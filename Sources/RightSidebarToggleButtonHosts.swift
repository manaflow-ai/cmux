import CmuxSettings
import CmuxSettingsUI
import SwiftUI

/// Window-level owner of the persistent right-sidebar button.
///
/// Mounted once per main window above the content and titlebar band. It draws
/// the `titlebar` placement in the window's top-trailing corner and keeps the
/// window's top-right tab bar inset in sync with the resolved layout, so the
/// tab bar never renders its action buttons under the button.
struct RightSidebarToggleWindowChrome: View {
    @ObservedObject var fileExplorerState: FileExplorerState
    let tabManager: TabManager

    @LiveSetting(\.rightSidebar.toggleButton) private var placement
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var layout: RightSidebarToggleButtonLayout {
        RightSidebarToggleButtonLayout.resolve(
            placement: placement,
            isMinimalMode: WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal,
            isRightSidebarVisible: fileExplorerState.isVisible
        )
    }

    var body: some View {
        let layout = layout
        ZStack(alignment: .topTrailing) {
            Color.clear
                .allowsHitTesting(false)
            if layout.showsCornerButton {
                RightSidebarToggleButton(
                    placement: .titlebar,
                    isRightSidebarVisible: fileExplorerState.isVisible
                )
                .frame(height: WindowChromeMetrics.appTitlebarHeight)
                .padding(.trailing, RightSidebarToggleButtonLayout.trailingPadding)
            }
        }
        .onAppear { syncTabBarTrailingInset(layout.tabBarTrailingInset) }
        .onChange(of: layout.tabBarTrailingInset) { _, inset in syncTabBarTrailingInset(inset) }
    }

    private func syncTabBarTrailingInset(_ inset: CGFloat) {
        tabManager.syncWorkspaceTabBarTrailingInset(inset)
    }
}

/// Draws the `paneTabBar` placement over the trailing inset that the
/// workspace's top-right tab bar reserves. Attach it to the workspace content
/// region (left of the right sidebar), whose top edge is the tab bar row.
struct RightSidebarTogglePaneTabBarHost: View {
    @ObservedObject var fileExplorerState: FileExplorerState
    let isWorkspaceContentShown: Bool

    @LiveSetting(\.rightSidebar.toggleButton) private var placement

    var body: some View {
        if placement == .paneTabBar, isWorkspaceContentShown {
            RightSidebarToggleButton(
                placement: .paneTabBar,
                isRightSidebarVisible: fileExplorerState.isVisible
            )
            .frame(height: WindowChromeMetrics.bonsplitTabBarHeight)
            .padding(.trailing, RightSidebarToggleButtonLayout.trailingPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }
}

/// Draws the `sidebarFooter` placement at the trailing end of the left
/// sidebar footer.
struct RightSidebarToggleSidebarFooterHost: View {
    @ObservedObject var fileExplorerState: FileExplorerState

    @LiveSetting(\.rightSidebar.toggleButton) private var placement

    var body: some View {
        if placement == .sidebarFooter {
            RightSidebarToggleButton(
                placement: .sidebarFooter,
                isRightSidebarVisible: fileExplorerState.isVisible
            )
        }
    }
}

import CmuxMobileSupport
import SwiftUI

/// Single owner for the workspace detail's leading navigation chrome.
///
/// Keep the back button and title in one leading toolbar content owner so
/// SwiftUI cannot promote the title into the centered principal slot. Each
/// control keeps its own island styling, while the shared toolbar item keeps
/// the cluster left-aligned across detail transitions.
struct WorkspaceLeadingToolbarChrome<TitleLabel: View, MenuContent: View>: ToolbarContent {
    let backButtonConfiguration: WorkspaceBackButtonConfiguration?
    let contentWidth: CGFloat
    let hasTrailingCluster: Bool
    let hasChatToggle: Bool
    let isTitleMenuEnabled: Bool
    @ViewBuilder let menuContent: () -> MenuContent
    @ViewBuilder let titleLabel: () -> TitleLabel

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: MobileNavTitleWidth.interControlSpacing) {
                if let backButtonConfiguration {
                    WorkspaceBackButton(
                        unreadCount: backButtonConfiguration.unreadCount,
                        badgeContrast: backButtonConfiguration.badgeContrast,
                        action: backButtonConfiguration.action
                    )
                    .mobileGlassCompactToolbarControl()
                    .fixedSize(horizontal: true, vertical: false)
                }

                WorkspaceTitleMenu(
                    contentWidth: contentWidth,
                    hasBackButton: backButtonConfiguration != nil,
                    hasTrailingCluster: hasTrailingCluster,
                    hasChatToggle: hasChatToggle,
                    isEnabled: isTitleMenuEnabled,
                    menuContent: menuContent,
                    label: titleLabel
                )
            }
        }
    }
}

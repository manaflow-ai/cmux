#if os(iOS)
import CmuxAgentChatUI
import CmuxMobileSupport
import SwiftUI

extension WorkspaceDetailView {
    @ViewBuilder
    var workspaceTopChrome: some View {
        WorkspaceDetailTopChrome(
            backAction: backAction,
            backUnreadCount: backUnreadCount,
            title: {
                workspaceTopChromeTitle
            },
            trailing: {
                toolbarTrailingCluster
            }
        )
    }

    @ViewBuilder
    private var workspaceTopChromeTitle: some View {
        if isChatMode,
           let session = chosenChatSession,
           let conversation = chatConversationStores[session.id] {
            ChatSessionHeaderView(
                descriptor: conversation.descriptor,
                agentState: conversation.agentState,
                isConnected: conversation.isConnected,
                titleOverride: workspace.name,
                subtitle: tabName(for: session)
            )
            .frame(maxWidth: MobileNavTitleWidth.cap(
                contentWidth: contentWidth,
                hasChatToggle: true
            ))
            .mobileGlassNavigationTitle()
        } else {
            glassTitle(activeBrowser?.title ?? workspace.name)
        }
    }
}

private struct WorkspaceDetailTopChrome<Title: View, Trailing: View>: View {
    let backAction: (() -> Void)?
    let backUnreadCount: Int
    let title: () -> Title
    let trailing: () -> Trailing

    init(
        backAction: (() -> Void)?,
        backUnreadCount: Int,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.backAction = backAction
        self.backUnreadCount = backUnreadCount
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                leadingSlot
                Spacer(minLength: 0)
                trailing()
            }
            .frame(height: 44)

            title()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var leadingSlot: some View {
        if let backAction {
            WorkspaceBackButton(
                unreadCount: backUnreadCount,
                badgeContrast: .darkBackground,
                action: backAction
            )
            .foregroundStyle(TerminalPalette.foreground)
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, 10)
            .mobileGlassPill()
        } else {
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}
#endif

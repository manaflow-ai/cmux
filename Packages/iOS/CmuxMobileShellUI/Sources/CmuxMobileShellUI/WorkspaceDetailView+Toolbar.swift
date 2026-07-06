#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileBrowser
import CmuxMobileSupport
import SwiftUI

extension WorkspaceDetailView {
    @ToolbarContentBuilder
    var workspaceDetailToolbar: some ToolbarContent {
        ToolbarItem(id: "workspace-toolbar", placement: .principal) {
            workspaceToolbarContainer
        }
    }

    /// The whole top bar as a single principal item: back, title/subtitle, and
    /// the trailing controls in one layout so `.layoutPriority` can rank them.
    /// Each island keeps its own Liquid Glass backing so the bar still reads as
    /// three separate capsules.
    @ViewBuilder
    private var workspaceToolbarContainer: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                workspaceToolbarLayout
            }
        } else {
            workspaceToolbarLayout
        }
    }

    private var workspaceToolbarLayout: some View {
        HStack(spacing: workspaceToolbarIslandSpacing) {
            if backButtonConfiguration != nil {
                workspaceBackToolbarIsland
            }

            // The title/subtitle yields first: lower layout priority than the
            // trailing controls, so it truncates rather than pushing them out
            // or collapsing them into the system overflow menu.
            workspaceTitleToolbarMenu
                .layoutPriority(0)

            Spacer(minLength: 0)

            workspaceTrailingToolbarIsland
                .layoutPriority(1)
        }
        // The navigation bar measures a principal item at its ideal width and
        // centers the result. Report the container width as the ideal so UIKit
        // caps it to the inset toolbar region, while `maxWidth` keeps the
        // layout compressible and fills the capped proposal without overflow.
        .frame(idealWidth: workspaceToolbarIdealWidth, maxWidth: .infinity, alignment: .leading)
    }

    private var workspaceToolbarIdealWidth: CGFloat? {
        toolbarContentWidth > 0 ? toolbarContentWidth : nil
    }

    private var workspaceBackToolbarIsland: some View {
        workspaceBackToolbarButton
            .mobileGlassCircle()
            .layoutPriority(1)
    }

    @ViewBuilder
    private var workspaceTrailingToolbarIsland: some View {
        if #available(iOS 26.0, *) {
            toolbarTrailingCluster
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            toolbarTrailingCluster
        }
    }

    private var workspaceToolbarIslandSpacing: CGFloat { 10 }

    private var workspaceTitleToolbarMenu: some View {
        WorkspaceTitleMenu(
            isEnabled: hasTitleMenuActions,
            menuContent: { titleMenuContent }
        ) {
            toolbarTitleLabel
        }
    }

    @ViewBuilder
    private var toolbarTitleLabel: some View {
        if isChatMode,
           let session = chosenChatSession,
           let conversation = chatConversationStores[session.id] {
            ChatSessionHeaderView(
                descriptor: conversation.descriptor,
                agentState: conversation.agentState,
                isConnected: conversation.isConnected,
                titleOverride: workspace.name,
                subtitle: tabName(for: session),
                style: .toolbarCompact
            )
        } else if let browser = activeBrowser {
            Text(browser.title ?? workspace.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(TerminalPalette.foreground)
        } else {
            WorkspaceToolbarTitleView(title: workspace.name, subtitle: selectedToolbarSubtitle)
        }
    }
}
#endif

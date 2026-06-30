#if DEBUG
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileSupport
import Foundation
import SwiftUI

/// Debug-only host for the agent chat surface fed by the fixture
/// conversation, so the chat UI is verifiable on a simulator before a Mac
/// host serves real transcripts.
struct AgentChatDemoScreen: View {
    let style: AgentChatDemoScreenStyle

    @Environment(\.dismiss) private var dismiss
    @State private var stack: DemoStack?
    @State private var draft = ""
    @State private var contentWidth: CGFloat = 0

    init(style: AgentChatDemoScreenStyle = .standalone) {
        self.style = style
    }

    var body: some View {
        NavigationStack {
            Group {
                if let stack {
                    chatScreen(for: stack)
                } else {
                    ProgressView()
                        .task {
                            let (messages, descriptor) = ChatFixtureConversation().make()
                            let source = FixtureChatEventSource(backlog: messages, replyToSends: true)
                            stack = DemoStack(
                                store: ChatConversationStore(descriptor: descriptor, source: source)
                            )
                        }
                }
            }
            .toolbar {
                if style == .standalone {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("mobile.common.done", defaultValue: "Done")) { dismiss() }
                            .accessibilityIdentifier("AgentChatDemoDone")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chatScreen(for stack: DemoStack) -> some View {
        switch style {
        case .standalone:
            baseChatScreen(for: stack)
                .mobileTerminalNavigationChrome()
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        header(for: stack)
                    }
                }
        case .inlineWorkspace:
            baseChatScreen(for: stack)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        WorkspaceBackButton(
                            unreadCount: 0,
                            badgeContrast: .darkBackground,
                            action: {}
                        )
                    }
                    if #available(iOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: .topBarLeading)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button(L10n.string("mobile.workspace.rename.title", defaultValue: "Rename Workspace")) {}
                                .accessibilityIdentifier("MobileWorkspaceTitleRenameMenuItem")
                            Button(L10n.string("mobile.workspace.markRead", defaultValue: "Mark as Read")) {}
                                .accessibilityIdentifier("MobileWorkspaceTitleMarkReadMenuItem")
                        } label: {
                            header(for: stack)
                                .frame(
                                    minWidth: MobileNavTitleWidth.floor,
                                    maxWidth: MobileNavTitleWidth(
                                        contentWidth: contentWidth,
                                        hasBackButton: true,
                                        hasChatToggle: true
                                    ).leadingCap,
                                    alignment: .leading
                                )
                                .layoutPriority(1)
                        }
                        .mobileGlassCompactToolbarControl()
                        .accessibilityIdentifier("MobileWorkspaceTitleMenu")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mobileChatTopScrollEdgeLayout(legacyTopPadding: 4)
                .mobileTerminalNavigationChrome()
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(action: {}) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                        }
                        .accessibilityIdentifier("AgentChatInlinePreviewChatToggle")
                        Button(action: {}) {
                            Image(systemName: "rectangle.stack")
                        }
                        .accessibilityIdentifier("AgentChatInlinePreviewTerminalPicker")
                    }
                }
        }
    }

    private func baseChatScreen(for stack: DemoStack) -> some View {
        ChatScreen(
            store: stack.store,
            draft: $draft,
            providesOwnChrome: false,
            onOpenTerminal: {}
        )
    }

    private func header(for stack: DemoStack) -> some View {
        ChatSessionHeaderView(
            descriptor: stack.store.descriptor,
            agentState: stack.store.agentState,
            isConnected: stack.store.isConnected,
            titleOverride: style == .inlineWorkspace ? inlineWorkspaceTitle : nil,
            subtitle: style == .inlineWorkspace ? inlineWorkspaceSubtitle : nil,
            style: style == .inlineWorkspace ? .toolbarCompact : .regular
        )
    }

    private var inlineWorkspaceTitle: String? {
        guard style == .inlineWorkspace else { return nil }
        return UITestConfig.value(
            for: "CMUX_UITEST_INLINE_WORKSPACE_TITLE",
            env: ProcessInfo.processInfo.environment
        ) ?? "cmux"
    }

    private var inlineWorkspaceSubtitle: String? {
        guard style == .inlineWorkspace else { return nil }
        return UITestConfig.value(
            for: "CMUX_UITEST_INLINE_WORKSPACE_SUBTITLE",
            env: ProcessInfo.processInfo.environment
        ) ?? "cmuxterm-hq"
    }

    /// Holds the demo's store so its identity is stable across re-renders.
    private struct DemoStack {
        let store: ChatConversationStore
    }
}
#endif

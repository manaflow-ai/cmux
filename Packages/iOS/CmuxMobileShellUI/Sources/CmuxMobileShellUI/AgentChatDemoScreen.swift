#if DEBUG
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileSupport
import SwiftUI

/// Debug-only host for the agent chat surface fed by the fixture
/// conversation, so the chat UI is verifiable on a simulator before a Mac
/// host serves real transcripts.
struct AgentChatDemoScreen: View {
    let style: AgentChatDemoScreenStyle

    @Environment(\.dismiss) private var dismiss
    @State private var stack: DemoStack?
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("AgentChatDemoDone")
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
                    ToolbarItem(placement: .principal) {
                        header(for: stack)
                            .frame(maxWidth: MobileNavTitleWidth.cap(
                                contentWidth: contentWidth,
                                hasChatToggle: true
                            ))
                            .mobileGlassNavigationTitle()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaPadding(.top, 4)
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
            providesOwnChrome: false,
            onOpenTerminal: {}
        )
    }

    private func header(for stack: DemoStack) -> some View {
        ChatSessionHeaderView(
            descriptor: stack.store.descriptor,
            agentState: stack.store.agentState,
            isConnected: stack.store.isConnected
        )
    }

    /// Holds the demo's store so its identity is stable across re-renders.
    private struct DemoStack {
        let store: ChatConversationStore
    }
}
#endif

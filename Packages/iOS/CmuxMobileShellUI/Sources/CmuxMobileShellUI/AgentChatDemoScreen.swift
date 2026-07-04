#if DEBUG
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileSupport
import CmuxMobileTerminal
import Foundation
import SwiftUI

/// Debug-only host for the agent chat surface fed by the fixture
/// conversation, so the chat UI is verifiable on a simulator before a Mac
/// host serves real transcripts.
struct AgentChatDemoScreen: View {
    let style: AgentChatDemoScreenStyle

    @Environment(\.dismiss) private var dismiss
    @State private var stack: DemoStack?

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
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        WorkspaceBackButton(
                            unreadCount: 0,
                            badgeContrast: .darkBackground,
                            action: {}
                        )
                    }
                    ToolbarItem(placement: .principal) {
                        WorkspaceTitleMenu {
                            Button(L10n.string("mobile.workspace.rename.title", defaultValue: "Rename Workspace")) {}
                                .accessibilityIdentifier("MobileWorkspaceTitleRenameMenuItem")
                            Button(L10n.string("mobile.workspace.markRead", defaultValue: "Mark as Read")) {}
                                .accessibilityIdentifier("MobileWorkspaceTitleReadStateMenuItem")
                        } label: {
                            header(for: stack)
                        }
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
        switch style {
        case .standalone:
            ChatScreen(
                store: stack.store,
                providesOwnChrome: false,
                onOpenTerminal: {}
            )
        case .inlineWorkspace:
            ChatScreen(
                store: stack.store,
                accessoryLeadingShortcuts: previewLeadingShortcuts,
                accessoryShortcuts: previewScrollableShortcuts(for: stack),
                providesOwnChrome: false,
                onOpenTerminal: {}
            )
        }
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

    private var previewLeadingShortcuts: [ChatAccessoryShortcut] {
        [
            ChatAccessoryShortcut(
                id: "terminal.inputAccessory.hideKeyboard",
                title: "",
                systemImage: "keyboard.chevron.compact.down",
                accessibilityLabel: L10n.string(
                    "terminal.input_accessory.hideKeyboard",
                    defaultValue: "Hide Keyboard"
                ),
                tint: .secondary,
                semanticAction: .dismissKeyboard
            ) {},
            ChatAccessoryShortcut(
                id: "terminal.inputAccessory.composer",
                title: "",
                systemImage: "terminal",
                accessibilityLabel: L10n.string(
                    "mobile.terminal.select",
                    defaultValue: "Terminal"
                )
            ) {},
        ]
    }

    private func previewScrollableShortcuts(for stack: DemoStack) -> [ChatAccessoryShortcut] {
        TerminalInputAccessoryAction.defaultConfigurableOrder.compactMap { action in
            guard action.isSupportedInAgentChat else { return nil }
            return ChatAccessoryShortcut(
                id: action.accessibilityIdentifier,
                title: action.title(isMacRemote: true),
                systemImage: action.symbolName,
                accessibilityLabel: action.accessibilityLabel ?? action.settingsDisplayName,
                semanticAction: action == .paste ? .paste : nil
            ) {
                performPreviewShortcut(action, store: stack.store)
            }
        }
    }

    private func performPreviewShortcut(
        _ action: TerminalInputAccessoryAction,
        store: ChatConversationStore
    ) {
        switch action {
        case .escape:
            Task { await store.interrupt(hard: false) }
        case .ctrlC:
            Task { await store.interrupt(hard: true) }
        default:
            break
        }
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

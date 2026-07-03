#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI
import UIKit

/// The agent chat rendered inline in the workspace detail, in place of the
/// terminal, when chat mode is toggled on. There is no cover and no Done
/// button: the same toolbar toggle flips back to the terminal.
struct WorkspaceChatPane: View {
    let session: ChatSessionDescriptor
    let conversation: ChatConversationStore
    let store: CMUXMobileShellStore
    /// Composer draft, owned by the parent so it survives toggling back to
    /// the terminal and returning mid-thought.
    @Binding var draft: String
    /// Flips chat mode off (the toggle's "back to terminal" path).
    let onExitChat: () -> Void

    @Environment(BrowserSurfaceStore.self) private var browserStore

    @State private var accessoryConfiguration = TerminalAccessoryConfiguration.shared
    @State private var isShowingShortcutSettings = false

    var body: some View {
        Group {
            ChatScreen(
                store: conversation,
                draft: $draft,
                accessoryLeadingShortcuts: chatAccessoryLeadingShortcuts(),
                accessoryShortcuts: chatAccessoryShortcuts(for: conversation),
                providesOwnChrome: false,
                runsStoreTask: false,
                onOpenTerminal: openTerminal
            )
        }
        .sheet(isPresented: $isShowingShortcutSettings) {
            TerminalShortcutsSettingsView(scope: .agentChat)
        }
    }

    /// The escape hatch: select the session's terminal surface, then leave
    /// chat mode so the terminal shows.
    private func openTerminal() {
        if let terminalID = session.terminalID {
            // Leaving chat for the terminal is a chrome action, not a typing
            // intent, so suppress the target's autofocus (matches the terminal
            // picker). Using selectTerminalFromChrome instead of setting
            // selectedTerminalID directly avoids a surprise keyboard pop.
            store.selectTerminalFromChrome(MobileTerminalPreview.ID(rawValue: terminalID))
        }
        // Close any active browser pane for this workspace first: the detail
        // body prefers browser over terminal, so leaving a browser open would
        // make "Open Terminal" land back on the browser instead of the
        // terminal the user asked for (matches the terminal-picker path).
        if let workspaceID = session.workspaceID {
            browserStore.closeBrowser(for: workspaceID)
        }
        onExitChat()
    }

    private func chatAccessoryLeadingShortcuts() -> [ChatAccessoryShortcut] {
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
                ),
                action: openTerminal
            ),
        ]
    }

    private func chatAccessoryShortcuts(
        for conversation: ChatConversationStore
    ) -> [ChatAccessoryShortcut] {
        accessoryConfiguration.enabledItems.compactMap { item in
            chatAccessoryShortcut(for: item, conversation: conversation)
        } + [
            ChatAccessoryShortcut(
                id: "terminal.inputAccessory.customize",
                title: "",
                systemImage: "slider.horizontal.3",
                accessibilityLabel: L10n.string(
                    "terminal.input_accessory.customize",
                    defaultValue: "Customize Toolbar"
                ),
                tint: .secondary
            ) {
                isShowingShortcutSettings = true
            },
        ]
    }

    private func chatAccessoryShortcut(
        for item: ResolvedToolbarItem,
        conversation: ChatConversationStore
    ) -> ChatAccessoryShortcut? {
        switch item {
        case let .builtin(action):
            guard action.isSupportedInAgentChat else { return nil }
            return ChatAccessoryShortcut(
                id: action.accessibilityIdentifier,
                title: action.title(isMacRemote: true),
                systemImage: action.symbolName,
                accessibilityLabel: action.accessibilityLabel ?? action.settingsDisplayName,
                semanticAction: action == .paste ? .paste : nil
            ) {
                performChatAccessoryAction(action, conversation: conversation)
            }
        case let .custom(custom):
            guard let output = custom.output,
                  let text = String(data: output, encoding: .utf8) else {
                return nil
            }
            return ChatAccessoryShortcut(
                id: "terminal.inputAccessory.custom.\(custom.id.uuidString)",
                title: custom.title,
                systemImage: validSymbolName(custom.symbolName),
                accessibilityLabel: custom.title
            ) {
                sendSessionTerminalInput(text)
            }
        }
    }

    private func performChatAccessoryAction(
        _ action: TerminalInputAccessoryAction,
        conversation: ChatConversationStore
    ) {
        switch action {
        case .escape:
            Task { await conversation.interrupt(hard: false) }
        case .ctrlC:
            Task { await conversation.interrupt(hard: true) }
        case .paste:
            break
        default:
            guard let output = action.output,
                  let text = String(data: output, encoding: .utf8) else {
                return
            }
            sendSessionTerminalInput(text)
        }
    }

    private func sendSessionTerminalInput(_ text: String) {
        guard let terminalID = session.terminalID,
              let data = text.data(using: .utf8)
        else { return }
        Task {
            await store.submitTerminalRawInput(data, surfaceID: terminalID)
        }
    }

    private func validSymbolName(_ symbolName: String?) -> String? {
        guard let symbolName,
              !symbolName.isEmpty,
              UIImage(systemName: symbolName) != nil
        else {
            return nil
        }
        return symbolName
    }
}
#endif

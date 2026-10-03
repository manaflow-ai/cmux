import AppKit
import CmuxNextAgentPane
import os

/// Quick Agent Chat (`palette.quickAgentChat`): one agent chat in a floating
/// panel over any app. Every entrypoint (the global hot key, the palette,
/// the menu, the CLI) runs `toggle`. The chat is made on first show and kept
/// while the panel is hidden, so its draft survives Esc and a click away;
/// opening it in the main window starts the next show from a fresh chat.
final class QuickComposerController {
    /// A new quick chat's page, nil when this build has no agent page.
    private let makeChat: () -> AgentPaneView?
    private let makeWindow: () -> any QuickComposerWindow
    /// Opens `session` (nil: a new chat) as a tab in the main window and
    /// brings that window forward; false when there was nowhere to open it.
    private let openInWindow: (String?) -> Bool
    private var window: (any QuickComposerWindow)?
    /// The hosted chat, kept while the panel is hidden.
    private(set) var chat: AgentPaneView?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.quickComposer")

    init(
        makeChat: @escaping () -> AgentPaneView?,
        makeWindow: @escaping () -> any QuickComposerWindow,
        openInWindow: @escaping (String?) -> Bool
    ) {
        self.makeChat = makeChat
        self.makeWindow = makeWindow
        self.openInWindow = openInWindow
    }

    var isShown: Bool { window?.isVisible == true }

    /// Hides the panel when it is in front with the keys, else shows it
    /// and gives the composer the keys.
    func toggle() {
        if let window, window.isVisible, window.isKeyWindow {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let chat = chat ?? adoptNewChat() else {
            logger.notice("quick agent chat unavailable: this build has no agent page")
            return
        }
        let window = window ?? makeWindowOnce()
        window.present(chat, focus: chat.webView)
    }

    /// Orders the panel out; the chat and its draft stay.
    func hide() {
        window?.dismiss()
    }

    /// The page's ⌘Return or header button: the chat goes to the main
    /// window, and the panel starts over empty next time.
    func openChatInWindow(session: String?) {
        hide()
        // Nowhere to open it (no window yet): the chat stays in the panel.
        guard openInWindow(session ?? chat?.model.sessionId), let used = chat else { return }
        chat = nil
        // The page's request is still being answered; close it after.
        // task-owner: one-shot close of the handed-off page
        Task { used.close() }
    }

    private func adoptNewChat() -> AgentPaneView? {
        guard let chat = makeChat() else { return nil }
        chat.model.onQuickDismiss = { [weak self] in self?.hide() }
        chat.model.onQuickOpenInWindow = { [weak self] session in self?.openChatInWindow(session: session) }
        self.chat = chat
        return chat
    }

    private func makeWindowOnce() -> any QuickComposerWindow {
        let window = makeWindow()
        // Like ChatGPT's and Claude's quick entry: a click anywhere else puts it away.
        window.onResignKey = { [weak self] in self?.hide() }
        window.onCancel = { [weak self] in self?.hide() }
        self.window = window
        return window
    }
}

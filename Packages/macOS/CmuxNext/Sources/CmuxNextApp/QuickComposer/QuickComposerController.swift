import AppKit
import CmuxNextAgentPane
import os

/// Start Agent (`palette.quickAgentChat`, cx-hkat): one agent chat in a
/// floating panel over any app. Every entrypoint (its key, the opt-in
/// system-wide key, the palette, the menu, the CLI) runs `toggle`. The chat
/// is made on first show and kept while the panel is hidden, so its draft
/// survives Esc and a click away. Return starts it in the background (it
/// goes to the sidebar), ⌘Return starts it and opens it in the main window;
/// either way the next show is a fresh chat.
final class QuickComposerController {
    /// A new quick chat's page, nil when this build has no agent page.
    private let makeChat: () -> AgentPaneView?
    private let makeWindow: () -> any QuickComposerWindow
    /// Opens `session` (nil: a new chat) as a tab in the main window and
    /// brings that window forward; false when there was nowhere to open it.
    private let openInWindow: (String?) -> Bool
    /// Puts a started chat in the sidebar without bringing a window forward;
    /// false when there was nowhere to put it (daemon offline, workspace
    /// creation failed).
    private let startInBackground: @MainActor (AgentPaneQuickStart) async -> Bool
    private var window: (any QuickComposerWindow)?
    /// The hosted chat, kept while the panel is hidden.
    private(set) var chat: AgentPaneView?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.quickComposer")

    init(
        makeChat: @escaping () -> AgentPaneView?,
        makeWindow: @escaping () -> any QuickComposerWindow,
        openInWindow: @escaping (String?) -> Bool,
        startInBackground: @escaping @MainActor (AgentPaneQuickStart) async -> Bool
    ) {
        self.makeChat = makeChat
        self.makeWindow = makeWindow
        self.openInWindow = openInWindow
        self.startInBackground = startInBackground
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
        guard openInWindow(session ?? chat?.model.sessionId) else { return }
        releaseChat()
    }

    /// The page's Return: the panel hides, the started chat goes to the
    /// sidebar in the background, and the next show is a fresh chat. When it
    /// could not be placed the panel comes back with the chat, so the
    /// session is never left with nowhere to show it.
    func startChatInBackground(_ start: AgentPaneQuickStart) async {
        hide()
        guard await startInBackground(start) else {
            logger.error("start agent: the started chat could not be placed; it stays in the panel")
            show()
            return
        }
        releaseChat()
    }

    /// Lets go of the handed-off chat; the next show makes a new one.
    private func releaseChat() {
        guard let used = chat else { return }
        chat = nil
        // The page's request is still being answered; close it after.
        // task-owner: one-shot close of the handed-off page
        Task { used.close() }
    }

    private func adoptNewChat() -> AgentPaneView? {
        guard let chat = makeChat() else { return nil }
        chat.model.onQuickDismiss = { [weak self] in self?.hide() }
        chat.model.onQuickOpenInWindow = { [weak self] session in self?.openChatInWindow(session: session) }
        chat.model.onQuickStartInBackground = { [weak self] start in await self?.startChatInBackground(start) }
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

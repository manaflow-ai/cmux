import AppKit
import CmuxNextAgentPane
import CmuxNextFloating
import os

/// Start Agent (`palette.quickAgentChat`, cx-hkat): one agent chat in a
/// floating panel over any app. Every entrypoint (its key, the opt-in
/// system-wide key, the palette, the menu, the CLI) runs `toggle`. The chat
/// is made on first show and kept while the panel is hidden, so its draft
/// survives Esc and a click away. Return starts it in the background (it
/// goes to the sidebar), ⌘Return starts it and opens it in the main window;
/// either way the next show is a fresh chat. With the floating chat on
/// (cx-b9qi) Return keeps the started chat running in the panel instead,
/// until ⌘Return or the header moves it to a tab, and a chat tab's Move to
/// Floating Chat brings its session back into the panel. A chat the panel
/// holds when cmux quits comes back to it on the next show.
final class QuickComposerController {
    /// A quick chat's page on session `id` (nil: a new chat), nil when this
    /// build has no agent page.
    private let makeChat: (_ session: String?) -> AgentPaneView?
    private let makeWindow: () -> any QuickComposerWindow
    /// Opens `session` (nil: a new chat) as a tab in the main window and
    /// brings that window forward; false when there was nowhere to open it.
    private let openInWindow: (String?) -> Bool
    /// Puts a started chat in the sidebar without bringing a window forward;
    /// false when there was nowhere to put it (daemon offline, workspace
    /// creation failed).
    private let startInBackground: @MainActor (AgentPaneQuickStart) async -> Bool
    /// The floating chat (cx-b9qi): a started chat stays in the panel.
    private let floating: () -> Bool
    private var window: (any QuickComposerWindow)?
    /// The hosted chat, kept while the panel is hidden.
    private(set) var chat: AgentPaneView?
    /// The floating chat holds a started chat: it stays in the panel, which
    /// no longer hides on a click elsewhere.
    private(set) var holdsChat = false
    /// What the floating chat's page draws around its chat. Keep-on-top
    /// stays as chosen for the next floating chat.
    private(set) var floatingState = AgentPaneFloatingState()
    /// Sends the floating chat's state to its page (`AgentPaneFloatingState.push`).
    private let pushState: (AgentPaneFloatingState, AgentPaneView) -> Void
    /// What the user is looking at in cmux, for Include focused tab (`FloatingChatContext`).
    private let context: @MainActor () async -> AgentPaneQuickContext?
    /// Where the held chat's session is kept, so a quit does not lose it (`heldSessionKey`).
    private let defaults: UserDefaults
    static let heldSessionKey = "quickComposer.floatingChatSession"
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.quickComposer")

    init(
        makeChat: @escaping (_ session: String?) -> AgentPaneView?,
        makeWindow: @escaping () -> any QuickComposerWindow,
        openInWindow: @escaping (String?) -> Bool,
        startInBackground: @escaping @MainActor (AgentPaneQuickStart) async -> Bool,
        floating: @escaping () -> Bool = { QuickComposerTunables.floatingChat.value },
        pushState: @escaping (AgentPaneFloatingState, AgentPaneView) -> Void = { AgentPaneFloatingState.push($0, to: $1) },
        context: (@MainActor () async -> AgentPaneQuickContext?)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.makeChat = makeChat
        self.makeWindow = makeWindow
        self.openInWindow = openInWindow
        self.startInBackground = startInBackground
        self.floating = floating
        self.pushState = pushState
        self.context = context ?? { nil }
        self.defaults = defaults
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
        // The chat the floating chat held when cmux quit comes back to it (kept while the floating chat is off).
        if chat == nil, floating(), let held = defaults.string(forKey: Self.heldSessionKey) {
            if moveToFloatingChat(session: held) { return }
            defaults.removeObject(forKey: Self.heldSessionKey)
        }
        guard let chat = chat ?? makeChat(nil).map(adopt) else {
            logger.notice("quick agent chat unavailable: this build has no agent page")
            return
        }
        let window = window ?? makeWindowOnce()
        // Summoned to type in: a floating chat folded to its compact bar opens back out.
        if floatingState.collapsed { setCollapsed(false) }
        window.present(chat, focus: chat.focusTarget)
        // A Chromium page takes the keys in its own window once the panel shows.
        if chat.chromiumPage != nil { chat.focusChat() }
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
        // The floating chat keeps it running in the panel (each later prompt sends this again).
        if holdsChat || floating() {
            holdChat()
            return
        }
        hide()
        guard await startInBackground(start) else {
            logger.error("start agent: the started chat could not be placed; it stays in the panel")
            show()
            return
        }
        releaseChat()
    }

    /// A chat tab's Move to Floating Chat: the panel holds that session's
    /// chat, shown, and the tab can close. A chat the panel held goes to a tab
    /// first; a draft is dropped once the new chat is made. False when the
    /// floating chat is off, the held chat had nowhere to go (it stays), or
    /// this build has no agent page.
    func moveToFloatingChat(session: String) -> Bool {
        guard floating() else { return false }
        // The chat it held when cmux quit, not shown since, goes to a tab first, as a held chat does.
        if chat == nil, let held = defaults.string(forKey: Self.heldSessionKey), held != session {
            guard openInWindow(held) else { return false }
            defaults.removeObject(forKey: Self.heldSessionKey)
        }
        if holdsChat, let held = chat, held.model.sessionId != session {
            openChatInWindow(session: held.model.sessionId)
            // Nowhere to open it: the held chat comes back and the tab stays.
            guard !holdsChat else { show(); return false }
        }
        if !holdsChat {
            guard let made = makeChat(session) else { return false }
            releaseChat()
            adopt(made)
            if window == nil { _ = makeWindowOnce() }
            holdChat()
        }
        show()
        return true
    }

    private func holdChat() {
        guard !holdsChat else { return }
        holdsChat = true
        defaults.set(chat?.model.sessionId, forKey: Self.heldSessionKey)
        floatingState.holding = true
        window?.holdChat(true)
        window?.setOnTop(floatingState.onTop)
        pushFloatingState()
    }

    /// The page's keep-on-top button or key: only a held chat floats or not.
    func setOnTop(_ onTop: Bool) {
        guard holdsChat else { return }
        floatingState.onTop = onTop
        window?.setOnTop(onTop)
        pushFloatingState()
    }

    /// The page's compact bar button or key: only a held chat folds.
    func setCollapsed(_ collapsed: Bool) {
        guard holdsChat else { return }
        floatingState.collapsed = collapsed
        window?.setCollapsed(collapsed)
        pushFloatingState()
    }

    private func pushFloatingState() {
        if let chat { pushState(floatingState, chat) }
    }

    /// Lets go of the handed-off chat; the next show makes a new one.
    private func releaseChat() {
        if holdsChat {
            holdsChat = false
            defaults.removeObject(forKey: Self.heldSessionKey)
            if floatingState.collapsed { window?.setCollapsed(false) }
            floatingState = AgentPaneFloatingState(onTop: floatingState.onTop)
            window?.holdChat(false)
        }
        guard let used = chat else { return }
        chat = nil
        // The page's request is still being answered; close it after.
        // task-owner: one-shot close of the handed-off page
        Task { used.close() }
    }

    @discardableResult
    private func adopt(_ chat: AgentPaneView) -> AgentPaneView {
        chat.model.quick = AgentPaneQuickHooks(
            dismiss: { [weak self] in self?.hide() },
            openInWindow: { [weak self] session in self?.openChatInWindow(session: session) },
            startInBackground: { [weak self] start in await self?.startChatInBackground(start) },
            setOnTop: { [weak self] onTop in self?.setOnTop(onTop) },
            setCollapsed: { [weak self] collapsed in self?.setCollapsed(collapsed) },
            floatingState: { [weak self] in self?.floatingState ?? AgentPaneFloatingState() },
            context: { [weak self] in await self?.context() })
        // A held chat that moves to another session (a fork, Continue In) is the one a quit keeps.
        let started = chat.model.onSessionChange
        chat.model.onSessionChange = { [weak self] session in
            started?(session)
            if let self, self.holdsChat { self.defaults.set(session, forKey: Self.heldSessionKey) }
        }
        self.chat = chat
        return chat
    }

    private func makeWindowOnce() -> any QuickComposerWindow {
        let window = makeWindow()
        // Like ChatGPT's and Claude's quick entry: a click anywhere else puts it away,
        // unless the floating chat holds a running chat.
        window.onResignKey = { [weak self] in
            guard let self, !self.holdsChat else { return }
            self.hide()
        }
        window.onCancel = { [weak self] in self?.hide() }
        self.window = window
        return window
    }
}

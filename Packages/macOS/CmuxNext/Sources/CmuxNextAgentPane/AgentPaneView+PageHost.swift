public import AppKit
import CmuxNextPages

/// The agent pane on the shared page host (react-pages.md, agent pane move P2): the bundled page at
/// `cmux-page://cmux.agent/` in a ``PageWebView``, its calls answered by ``AgentPageProvider`` and
/// the host's pushes sent as ``AgentPageEvent``s.
extension AgentPaneView {
    /// Wires `page` to this view: navigation, crashes, and the state a new page subscriber gets.
    func attachPage(_ page: PageWebView) {
        page.autoresizingMask = [.width, .height]
        page.onOpenExternal = { [weak self] url in
            guard let self else { return }
            let modifiers = self.page.externalLinkModifiers
            _ = AgentPaneNavigation.openOutside(url, gestures: self.model.transport.gestures) { self.openURL($0, modifiers) }
        }
        page.onNavigate = { [weak self] navigation in
            guard let self else { return .cancel }
            switch AgentPaneNavigation.decision(for: navigation.url, userClicked: navigation.userClicked,
                                                mainFrame: navigation.mainFrame) {
            case .allow: return .allow
            case .openOutside: return .openExternal
            case .cancel: return .cancel
            }
        }
        // A reload builds the chat again without what its page held (an open menu, the caret, an
        // IME composition, unsent chips): a crash shows the notice, and Reload is the person's.
        page.reloadsAfterCrash = false
        page.onCrash = { [weak self] _, reloading in self?.pageCrashed(reloading: reloading) }
        page.onLoaded = { [weak self] in self?.pageLoaded() }
        pageEvents.replay = { [weak self] in
            // A new subscriber is a page that loaded again: its registry renderers are gone.
            guard let self else { return [] }
            self.runPageHostRegistry()
            let events = AgentPanePageHost.currentEvents(self)
            // The theme it gets here is the one it has now, whatever was pushed before.
            self.deliveredThemeEvent = events.first { $0.kind == "theme" }
            return events
        }
        addSubview(page)
    }

    /// The view that takes the keyboard when the chat is focused: Chromium's view when the page
    /// shows in Chromium (the `agent.chromium` spike), else the WebKit view.
    public var focusTarget: NSView { page.focusView }

    /// The engine the chat shows in, for `debug.agent_pane engine`: `cef`, or `webkit:<reason>`
    /// (``PageWebKitReason``).
    public var engineName: String {
        let decision = page.engineDecision
        return decision.engine == .cef ? "cef" : "webkit:\(decision.webKitReason?.rawValue ?? "none")"
    }

    /// Gives the chat the keyboard unless ``focusTarget`` already has it.
    public func focusChat() {
        guard let window, window.firstResponder !== focusTarget else { return }
        page.focusPage()
    }

    /// Runs `body` as an async function body in the chat's page, in whichever engine shows it
    /// (``PageWebView/callPageScript(_:arguments:)``).
    public func callPageScript(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await page.callPageScript(body, arguments: arguments)
    }
}

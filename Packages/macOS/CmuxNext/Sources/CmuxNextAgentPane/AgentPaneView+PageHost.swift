public import AppKit
import CmuxNextPages

/// The agent pane on the shared page host (react-pages.md, agent pane move P2): the bundled page at
/// `cmux-page://cmux.agent/` in a ``PageWebView``, its calls answered by ``AgentPageProvider`` and
/// the host's pushes sent as ``AgentPageEvent``s. The `agent.pageHost` tunable turns it on.
extension AgentPaneView {
    /// Runs once the chat has painted (``AgentPaneModel/whenPainted(_:)``), the gate the page is
    /// revealed on; the document's own first frame comes earlier and draws an empty chat.
    package func whenPagePainted(_ body: @escaping () -> Void) {
        model.whenPainted(body)
    }

    /// Wires `page` to this view: navigation, crashes, and the state a new page subscriber gets.
    func attachPage(_ page: PageWebView) {
        page.autoresizingMask = [.width, .height]
        page.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            // PageWebView has already revoked its isolated proof before this callback. Revoke
            // the native witness and cache too, even if AppKit calls an ancestor's hooks later.
            self.model.transport.gestures.recordQuestionReturn(false)
            self.questionKeyBinding = nil
            if visible { self.refreshQuestionKeyBinding() }
        }
        page.onQuestionKeyChannelInvalidated = { [weak self] in
            guard let self else { return }
            self.model.transport.gestures.recordQuestionReturn(false)
            // Keep the owner cache stable for this event. The channel has
            // already dropped its listener; the normal refresh path sees the
            // missing targets and reinstalls it. Defer that refresh so the
            // invalidation is observable synchronously and a Return that
            // follows it still gets a fresh binding.
            // task-owner: one deferred refresh for this invalidation; a released view is ignored.
            Task { @MainActor [weak self] in self?.refreshQuestionKeyBinding() }
        }
        page.onOpenExternal = { [weak self, weak page] url in
            guard let self else { return }
            let modifiers = page?.externalLinkModifiers ?? []
            _ = AgentPaneNavigation.openOutside(url, gestures: self.model.transport.gestures) { self.openURL($0, modifiers) }
        }
        page.onNavigate = { [weak self] navigation in
            guard let self else { return .cancel }
            switch AgentPaneNavigation.decision(for: navigation.url, source: self.source,
                                                userClicked: navigation.userClicked, mainFrame: navigation.mainFrame) {
            case .allow: return .allow
            case .openOutside: return .openExternal
            case .cancel: return .cancel
            }
        }
        // A reload builds the chat again without what its page held (an open menu, the caret, an
        // IME composition, unsent chips): a crash shows the notice, and Reload is the person's.
        page.reloadsAfterCrash = false
        page.onCrash = { [weak self] _, reloading in self?.pageCrashed(reloading: reloading) }
        page.onDocumentLoaded = { [weak self] in self?.pageLoadedAgain() }
        pageEvents?.replay = { [weak self] in
            // A new subscriber is a page that loaded again: its registry renderers are gone.
            guard let self else { return [] }
            self.questionKeyBinding = nil
            self.refreshQuestionKeyBinding()
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
    public var focusTarget: NSView { page?.focusView ?? webView }

    /// The engine the chat shows in, for `debug.agent_pane engine`: `cef`, `webkit:<reason>` on the
    /// page host (``PageWebKitReason``), or `webkit:own-host` on the pane's own WebKit host.
    public var engineName: String {
        guard let decision = page?.engineDecision else { return "webkit:own-host" }
        return decision.engine == .cef ? "cef" : "webkit:\(decision.webKitReason?.rawValue ?? "none")"
    }

    /// Gives the chat the keyboard unless ``focusTarget`` already has it.
    public func focusChat() {
        guard let window, window.firstResponder !== focusTarget else { return }
        if let page { page.focusPage() } else { window.makeFirstResponder(webView) }
    }

    /// Runs `body` as an async function body in the chat's page, in whichever engine shows it
    /// (``PageWebView/callPageScript(_:arguments:)``).
    public func callPageScript(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        if let page { return try await page.callPageScript(body, arguments: arguments) }
        return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }
}

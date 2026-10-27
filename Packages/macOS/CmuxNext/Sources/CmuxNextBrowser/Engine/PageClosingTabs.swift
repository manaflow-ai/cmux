/// Browser tabs whose page decides a person's close now (a live Chromium page runs its
/// beforeunload first, `BrowserUserClosing`): the tab stays in its strip until Chromium closes
/// the page, usually within a renderer round trip. While it does, a quick next Cmd-W closes the
/// next tab (the app's `TabCloseGuard.cmdWTarget`), not the same tab again, whose close
/// would only answer "still closing". Once the page asks ("Leave site?") the tab leaves this set:
/// the question is the person's, and a Cmd-W on the tab then shows it, as before.
@MainActor
public final class PageClosingTabs {
    /// How long a tab stays in the set when its page neither asks nor closes: Chromium itself closes a
    /// page whose beforeunload runs past `kUnloadTimeout` (500 ms, `RenderFrameHostImpl::BeforeUnloadTimeout`,
    /// content/browser/renderer_host/render_frame_host_impl.cc), so twice that leaves a round trip to spare.
    static let decideTimeout: Duration = .seconds(1)

    private var watches: [String: Task<Void, Never>] = [:]

    /// No tab closing.
    public init() {}

    /// The page of tab `id` began deciding its close.
    ///
    /// - Parameter id: The tab.
    /// - Parameter page: Its page; the tab leaves the set once the page asks or closes, or after
    ///   ``decideTimeout``.
    public func begin(_ id: String, page: any BrowserPageWaiting) {
        watches[id]?.cancel()
        // task-owner: this set (cancelled on end or a new begin); a keyed page wait (PageWaiters), read
        // only when the page adds a prompt, ends when the page asks or closes or after decideTimeout.
        // main-hop-allow: whenPrompt is the page's main-actor keyed wait (PageWaiters, R-wait); its resume only drops this set's entry
        watches[id] = Task { [weak self, weak page] in
            _ = await page?.whenPrompt(kind: { $0.isBeforeUnload }, timeout: Self.decideTimeout)
            guard !Task.isCancelled else { return }
            self?.watches[id] = nil
        }
    }

    /// Returns once tab `id`'s watch ended (tests: the page asked or closed, or the timeout passed).
    func watchEnded(_ id: String) async {
        await watches[id]?.value
    }

    /// Whether tab `id`'s page is still deciding a close no question shows for.
    public func contains(_ id: String) -> Bool { watches[id] != nil }

    /// Tab `id` left its strip (closed) or its close is over.
    public func end(_ id: String) {
        watches.removeValue(forKey: id)?.cancel()
    }

    nonisolated deinit {}
}

import CmuxNextCompat

/// Browser tabs whose page decides a person's close now (a live Chromium page runs its
/// beforeunload first, `BrowserUserClosing`): the tab stays in its strip until Chromium closes
/// the page, usually within a renderer round trip. While it does, a quick next Cmd-W closes the
/// next tab (the app's `TabCloseGuard.cmdWTarget`), not the same tab again, whose close
/// would only answer "still closing". Once the page asks ("Leave site?") the tab leaves this set:
/// the question is the person's, and a Cmd-W on the tab then shows it, as before.
@MainActor
public final class PageClosingTabs {
    private var watches: [String: Task<Void, Never>] = [:]

    /// No tab closing.
    public init() {}

    /// The page of tab `id` began deciding its close.
    ///
    /// - Parameter id: The tab.
    /// - Parameter page: Its page; the tab leaves the set once the page asks or goes away.
    public func begin(_ id: String, page: any BrowserTab) {
        watches[id]?.cancel()
        // task-owner: this set (cancelled on end or a new begin); event driven (Observation), ends
        // when the page asks or goes away.
        watches[id] = Task { [weak self, weak page] in
            for await asks in ObservationStream({ page.map { $0.pendingPrompts.contains { $0.kind.isBeforeUnload } } ?? true }) where asks {
                break
            }
            guard !Task.isCancelled else { return }
            self?.watches[id] = nil
        }
    }

    /// Whether tab `id`'s page is still deciding a close no question shows for.
    public func contains(_ id: String) -> Bool { watches[id] != nil }

    /// Tab `id` left its strip (closed) or its close is over.
    public func end(_ id: String) {
        watches.removeValue(forKey: id)?.cancel()
    }

    nonisolated deinit {}
}

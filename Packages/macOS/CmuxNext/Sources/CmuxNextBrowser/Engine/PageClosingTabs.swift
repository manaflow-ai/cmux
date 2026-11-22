import CmuxNextCompat

/// Browser tabs whose page decides a person's close now (a live Chromium page runs its
/// beforeunload first, `BrowserUserClosing`): the tab stays in its strip until Chromium closes
/// the page, usually within a renderer round trip. While it does, a quick next Cmd-W closes the
/// next tab (the app's `TabCloseGuard.cmdWTarget`), not the same tab again, whose close
/// would only answer "still closing". Once the page asks ("Leave site?") the tab leaves this set:
/// the question is the person's, and a Cmd-W on the tab then shows it, as before.
///
/// A page that never decides (a hung renderer: no question, never gone) leaves the set after ``limit``: before, it
/// stayed for good and every later Cmd-W skipped its tab and closed the next one. The limit is read in ``contains(_:)``,
/// so it costs no timer.
@MainActor
public final class PageClosingTabs {
    private var watches: [String: Task<Void, Never>] = [:]
    /// When each tab's page began deciding.
    private var began: [String: ContinuousClock.Instant] = [:]
    /// The clock ``limit`` is measured on (tests inject one).
    private let now: () -> ContinuousClock.Instant
    /// The longest a tab stays in this set: a renderer round trip is milliseconds, so a page still silent after two
    /// seconds is hung, and its tab is the next Cmd-W's again.
    public static let limit: Duration = .seconds(2)

    /// No tab closing.
    public init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// The page of tab `id` began deciding its close.
    ///
    /// - Parameter id: The tab.
    /// - Parameter page: Its page; the tab leaves the set once the page asks or goes away.
    public func begin(_ id: String, page: any BrowserTab) {
        watches[id]?.cancel()
        began[id] = now()
        // task-owner: this set (cancelled on end or a new begin); event driven (Observation), ends
        // when the page asks or goes away.
        watches[id] = Task { [weak self, weak page] in
            for await asks in ObservationStream({ page.map { $0.pendingPrompts.contains { $0.kind.isBeforeUnload } } ?? true }) where asks {
                break
            }
            guard !Task.isCancelled else { return }
            self?.watches[id] = nil
            self?.began[id] = nil
        }
    }

    /// Whether `page` asks the person its beforeunload question ("Leave site?") now: a tab hidden while
    /// its page decides comes back then.
    public static func asksPerson(_ page: any BrowserTab) -> @MainActor @Sendable () -> Bool {
        { [weak page] in page?.pendingPrompts.contains { $0.kind.isBeforeUnload && !$0.isResolved } ?? false }
    }

    /// Whether tab `id`'s page is still deciding a close no question shows for.
    public func contains(_ id: String) -> Bool {
        guard watches[id] != nil, let start = began[id] else { return false }
        return now() - start < Self.limit
    }

    /// Tab `id` left its strip (closed) or its close is over.
    public func end(_ id: String) {
        watches.removeValue(forKey: id)?.cancel()
        began[id] = nil
    }

    nonisolated deinit {}
}

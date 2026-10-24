public import CmuxNextSettings

/// What one page stream does with its events while its page is frozen (a hidden cmux page in
/// Chromium after the hibernation's grace, PageWebView+ChromiumCost.swift): a frozen renderer runs
/// no script, so no event may go into it, and a push must not thaw it either, or a page the host
/// keeps feeding never freezes (perf-lead.md F3: hidden cmux pages cost 0 CPU and 0 wakeups).
///
/// The router (``PageRouter``) keeps the subscription while the page is frozen and sends nothing.
/// A stream whose events replace each other keeps only the newest per key and sends those when
/// the page thaws: that is the page's fresh state, with no gap and no new subscribe. A stream
/// whose every event counts thaws the page for each event instead. Each provider says which its
/// stream is when it makes the ``PageSubscription``; there is no default, so a new stream decides.
///
/// ```swift
/// // The whole list in each event: the newest is the page's state.
/// return PageSubscription(freezing: .newest) { task.cancel() }
/// // Changes the page applies one by one (a diff's file events): each one thaws the page.
/// return PageSubscription(freezing: .every) { [weak self] in self?.events[id] = nil }
/// ```
public nonisolated struct PageStreamFreezing: Sendable {
    /// The key of an event: events with one key replace each other while the page is frozen; nil
    /// means the event cannot wait and thaws the page.
    let key: @Sendable (JSONValue) -> String?

    private init(key: @escaping @Sendable (JSONValue) -> String?) {
        self.key = key
    }

    /// Each event replaces the one before it: the stream's whole state, or a notice that the page
    /// reads again whatever it says. While the page is frozen only the newest is kept.
    public static let newest = PageStreamFreezing { _ in "" }

    /// Events replace earlier ones with the same `key` (a stream that carries several kinds of
    /// state, such as the agent page's theme, shortcuts and header). An event whose key is nil
    /// cannot wait: it thaws the page and goes at once.
    ///
    /// - Parameter key: The event's key, or nil for an event that must reach the page now.
    /// - Returns: The rule.
    public static func newest(by key: @escaping @Sendable (JSONValue) -> String?) -> PageStreamFreezing {
        PageStreamFreezing(key: key)
    }

    /// Every event counts (a log of changes the page applies one by one): an event that comes while
    /// the page is frozen thaws it, and the page's grace starts again.
    public static let every = PageStreamFreezing { _ in nil }
}

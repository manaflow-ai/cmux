import Foundation

/// The chats this app showed recently (Leo, 2026-11-18: "we shouldnt need to see spinners on loading switching
/// between chats most of the time"). A chat in here is one a pane of this app painted (the person saw it, or its
/// page drew it in a pane), and whose kept copy its page draws first (tailCache.ts, ``AgentPaneTailCache``, chatSnapshot/): a pane opened on it again, whether a hidden
/// chat whose page was given back and is built again, a sidebar open of it in another tab, or a spare that adopts
/// it, keeps its loading cover free of the busy mark however long its page takes
/// (``AgentPaneLoadingView/marksLoading``). Only a chat never shown in this app's life, or not for ``window``,
/// gets the mark after the beat.
///
/// Bounded two ways: the ``limit`` most recently shown chats, and only those shown within ``window``. Each entry
/// is a session id and an instant, so the store holds at most a few tens of KiB. ``AgentPaneTailCache`` owns it,
/// and its clear leaves this store be: it holds no content, only which chats showed, and every entry ends with
/// ``window``.
@MainActor
final class AgentPaneSeenChats {
    /// Most chats remembered.
    let limit: Int
    /// How long a chat counts as seen after it was last shown.
    let window: Duration
    private let clock: () -> ContinuousClock.Instant
    /// Session id to when it was last shown; `order` keeps them least recently shown first.
    private var shownAt: [String: ContinuousClock.Instant] = [:]
    private var order: [String] = []

    init(limit: Int = 256, window: Duration = .seconds(3_600), clock: @escaping () -> ContinuousClock.Instant = { .now }) {
        (self.limit, self.window, self.clock) = (limit, window, clock)
    }

    /// How many chats the store holds now.
    var count: Int { shownAt.count }

    /// Chat `session` showed on screen now.
    func noteShown(_ session: String) {
        let now = clock()
        dropExpired(now)
        if shownAt.updateValue(now, forKey: session) != nil { order.removeAll { $0 == session } }
        order.append(session)
        while order.count > limit { shownAt[order.removeFirst()] = nil }
    }

    /// Whether chat `session` showed within ``window``.
    func wasShown(_ session: String) -> Bool {
        guard let at = shownAt[session] else { return false }
        return clock() - at < window
    }

    private func dropExpired(_ now: ContinuousClock.Instant) {
        while let first = order.first, let at = shownAt[first], now - at >= window {
            order.removeFirst()
            shownAt[first] = nil
        }
    }
}

import Observation

/// Home retries the owner's loader even when reconnect is unavailable (previews or a live link).
@MainActor
struct HomeRetryAction {
    let feed: MacHomeFeed
    let reconnect: ((String) async -> Void)?
    let refresh: @MainActor () async -> Void

    /// `refresh` defaults to the feed's ``MacHomeFeed/reload()``: the retry ends when the read answers.
    init(feed: MacHomeFeed, reconnect: ((String) async -> Void)? = nil, refresh: (@MainActor () async -> Void)? = nil) {
        self.feed = feed
        self.reconnect = reconnect
        self.refresh = refresh ?? { await feed.reload() }
    }

    func retry(macID: String?, reconnectNeeded: Bool) async {
        if reconnectNeeded, let macID { await reconnect?(macID) }
        guard !Task.isCancelled else { return }
        await refresh()
    }
}

/// The screen owns the task; this state only publishes the latest load's result.
///
/// A conversation that was open keeps showing when the Mac's link drops
/// (CMUX-30): its last messages stay on screen, marked as not live by the
/// conversation's own bar (``ChiefSession/status``), instead of a full-screen
/// error. Only a first open with nothing to show fails (``failed``).
@MainActor
@Observable
final class MacConversationLoader {
    private(set) var session: ChiefSession?
    private(set) var failed = false
    /// ``session`` is the last one read from the Mac, not a live one.
    private(set) var isStale = false
    private(set) var retryID = 0
    @ObservationIgnored private var generation = 0

    /// The bar's title over a conversation kept from a dropped link.
    static var staleTitle: String { String(localized: "Not connected to your Mac") }
    /// The bar's line under it: what is shown and what happens to a send.
    static var staleReason: String {
        String(localized: "Showing the last messages. What you send waits until it reconnects.")
    }

    func retry(macID: String?, reconnect: ((String) async -> Void)?, refresh: (@MainActor () async -> Void)? = nil) async {
        if let macID { await reconnect?(macID) }
        guard !Task.isCancelled else { return }
        if let refresh { await refresh() }
        guard !Task.isCancelled else { return }
        retryID += 1
    }

    /// Loads the route's session. The session shown keeps showing while it loads;
    /// on a failure it stays, marked stale, with `tryAgain` on its bar.
    func load(_ sessionForRoute: @MainActor () async throws -> ChiefSession,
              tryAgain: (@MainActor () -> Void)? = nil) async {
        generation += 1
        let mine = generation
        let previous = session
        failed = false
        do {
            let loaded = try await sessionForRoute()
            guard mine == generation, !Task.isCancelled else { return }
            if let previous, previous !== loaded {
                // What was written while the link was down goes to the new session.
                for message in previous.outbox { loaded.send(message, asksForAlerts: false) }
                previous.discardOutbox()
                Self.clearStale(previous)
            }
            Self.clearStale(loaded)
            session = loaded
            isStale = false
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            if let previous {
                Self.markStale(previous, tryAgain: tryAgain)
                isStale = true
            } else {
                failed = true
            }
        }
    }

    /// Marks `session` as the last one read from a Mac that is not connected now.
    static func markStale(_ session: ChiefSession, tryAgain: (@MainActor () -> Void)?) {
        session.unavailableTitle = staleTitle
        session.reconnect = tryAgain
        session.status = staleReason
    }

    private static func clearStale(_ session: ChiefSession) {
        guard session.unavailableTitle == staleTitle else { return }
        session.unavailableTitle = nil
        session.reconnect = nil
        session.status = nil
    }
}

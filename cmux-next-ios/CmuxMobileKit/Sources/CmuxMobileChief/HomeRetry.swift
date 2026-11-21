import CmuxMobileDesign
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
///
/// A normal reconnect says nothing: the mark waits ``quiet`` (``QuietStatusGate/threshold``)
/// from the first failed read, and a live session before then clears the wait (Leo, 2026-11-16:
/// "it said "Not connected" at the top but i dont think it shoildve said anything").
@MainActor
@Observable
final class MacConversationLoader {
    private(set) var session: ChiefSession?
    private(set) var failed = false
    /// ``session`` is the last one read from the Mac, not a live one, for ``quiet`` or more.
    private(set) var isStale = false
    private(set) var retryID = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let quiet: Duration
    @ObservationIgnored private let clock: any Clock<Duration>
    /// The session shown while not live, and its Try Again, marked once ``quiet`` passes.
    @ObservationIgnored private var notLive: (session: ChiefSession, tryAgain: (@MainActor () -> Void)?)?
    @ObservationIgnored private var quietWait: Task<Void, Never>?

    init(quiet: Duration = QuietStatusGate.threshold, clock: any Clock<Duration> = ContinuousClock()) {
        self.quiet = quiet
        self.clock = clock
    }

    /// The bar's title over a conversation kept from a dropped link.
    static var staleTitle: String { String(localized: "Not connected to your Mac") }
    /// The bar's line under it: what is shown and what happens to a send.
    static var staleReason: String {
        String(localized: "What you send waits until it reconnects.")
    }


    func retry(macID: String?, reconnect: ((String) async -> Void)?, refresh: (@MainActor () async -> Void)? = nil) async {
        if let macID { await reconnect?(macID) }
        guard !Task.isCancelled else { return }
        if let refresh { await refresh() }
        guard !Task.isCancelled else { return }
        retryID += 1
    }

    /// Loads the route's session. The session shown keeps showing while it loads;
    /// on a failure it stays, marked stale (after ``quiet``), with `tryAgain` on its bar. A first
    /// open that fails shows `fallback` the same way (what this phone kept, or an empty
    /// conversation), never a full-screen error over the title and the composer (the user, 2026-11-13).
    func load(_ sessionForRoute: @MainActor () async throws -> ChiefSession,
              fallback: ChiefSession? = nil,
              tryAgain: (@MainActor () -> Void)? = nil) async {
        generation += 1
        let mine = generation
        let previous = session
        failed = false
        // A first open shows what was kept while its channel opens: not live, said only past the bound.
        if previous == nil, let fallback { holdNotLive(fallback, tryAgain: tryAgain) }
        do {
            let loaded = try await sessionForRoute()
            guard mine == generation, !Task.isCancelled else { return }
            // The one shown now: the previous session, or a first open's fallback shown past the bound.
            if let shown = session, shown !== loaded {
                Self.clearStale(shown)
            }
            endNotLive()
            Self.clearStale(loaded)
            session = loaded
            isStale = false
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            if let shown = previous ?? fallback {
                session = shown
                holdNotLive(shown, tryAgain: tryAgain)
            } else {
                failed = true
            }
        }
    }

    /// `shown` is not live: its bar says so once ``quiet`` has passed since it first was not
    /// (a retry that fails again keeps that first instant), at once when it already says so.
    private func holdNotLive(_ shown: ChiefSession, tryAgain: (@MainActor () -> Void)?) {
        if let held = notLive?.session, held !== shown { Self.clearStale(held) }
        notLive = (shown, tryAgain)
        if isStale {
            // The bound passed already: the new Try Again replaces the old (it also ends one in flight).
            Self.markStale(shown, tryAgain: tryAgain)
            return
        }
        guard quietWait == nil else { return }
        guard quiet > .zero else { return showNotLive() }
        let quiet = quiet
        let clock = clock
        // An intentional, bounded UI delay on the injected clock; a live session cancels it.
        quietWait = Task { [weak self] in
            do { try await clock.sleep(for: quiet) } catch { return }
            guard !Task.isCancelled else { return }
            self?.showNotLive()
        }
    }

    private func showNotLive() {
        quietWait = nil
        guard let notLive else { return }
        Self.markStale(notLive.session, tryAgain: notLive.tryAgain)
        // A first open still loading shows its fallback now: an empty one is never shown kept
        // (``MacConversationScreen``), so it would stay a spinner until the load gives up.
        if session == nil { session = notLive.session }
        isStale = true
    }

    private func endNotLive() {
        quietWait?.cancel()
        quietWait = nil
        if let held = notLive?.session { Self.clearStale(held) }
        notLive = nil
    }

    /// Marks `session` as the last one read from a Mac that is not connected now.
    static func markStale(_ session: ChiefSession, tryAgain: (@MainActor () -> Void)?) {
        session.unavailableTitle = staleTitle
        session.reconnect = tryAgain
        // One line whether or not kept messages are in yet (they can still be loading off the main thread).
        session.status = staleReason
    }

    private static func clearStale(_ session: ChiefSession) {
        guard session.unavailableTitle == staleTitle else { return }
        session.unavailableTitle = nil
        session.reconnect = nil
        session.status = nil
    }
}

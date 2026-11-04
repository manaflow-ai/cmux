import Observation

/// Home retries the owner's loader even when reconnect is unavailable (previews or a live link).
@MainActor
struct HomeRetryAction {
    let feed: MacHomeFeed
    let reconnect: ((String) async -> Void)?
    let refresh: () -> Void

    init(feed: MacHomeFeed, reconnect: ((String) async -> Void)? = nil, refresh: (() -> Void)? = nil) {
        self.feed = feed
        self.reconnect = reconnect
        self.refresh = refresh ?? { feed.refresh() }
    }

    func retry(macID: String?, reconnectNeeded: Bool) async {
        if reconnectNeeded, let macID { await reconnect?(macID) }
        guard !Task.isCancelled else { return }
        refresh()
    }
}

/// The screen owns the task; this state only publishes the latest load's result.
@MainActor
@Observable
final class MacConversationLoader {
    private(set) var session: ChiefSession?
    private(set) var failed = false
    private(set) var retryID = 0
    @ObservationIgnored private var generation = 0

    func retry(macID: String?, reconnect: ((String) async -> Void)?, refresh: (@MainActor () async -> Void)? = nil) async {
        if let macID { await reconnect?(macID) }
        guard !Task.isCancelled else { return }
        if let refresh { await refresh() }
        guard !Task.isCancelled else { return }
        retryID += 1
    }

    func load(_ sessionForRoute: @MainActor () async throws -> ChiefSession) async {
        generation += 1
        let mine = generation
        session = nil
        failed = false
        do {
            let loaded = try await sessionForRoute()
            guard mine == generation, !Task.isCancelled else { return }
            session = loaded
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            failed = true
        }
    }
}

import Observation

/// Home retries the owner's loader even when reconnect is unavailable (previews or a live link).
@MainActor
struct HomeRetryAction {
    let feed: MacHomeFeed
    let reconnect: ((String) -> Void)?

    func retry(macID: String?, reconnectNeeded: Bool) {
        if reconnectNeeded, let macID { reconnect?(macID) }
        feed.refresh()
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

    func retry(macID: String?, reconnect: ((String) -> Void)?) {
        if let macID { reconnect?(macID) }
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

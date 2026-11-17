import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHistory
import Foundation
import Observation

/// The hides of history the app cannot delete (agent sessions in the
/// daemons' append-only journals), as the home session's personal projection
/// `history.hidden` keeps them (plans/cmux-next/history.md 3). The daemon
/// history module is its only writer (Clear History, Remove from History);
/// this reads it on each connect, so `AgentHistory` leaves hidden sessions out.
final class HiddenHistoryStore {
    static let subject = "history.hidden"

    private unowned let services: AppServices
    private(set) var document = HiddenHistory()
    private var localHides = HiddenHistory()
    private var observation: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
        let store = services.daemon.store
        observation = Task { [weak self] in
            for await connected in ObservationStream({ if case .connected = store.connectionState { true } else { false } }) where connected {
                self?.load()
            }
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        observation?.cancel()
    }

    /// Hides at once, kept across loads (the daemon's clear or remove writes `history.hidden`; a load before it lands keeps them).
    func hideLocally(_ body: (inout HiddenHistory) -> Void) { body(&localHides); body(&document) }
    func loaded(_ stored: HiddenHistory) { document = stored.merged(with: localHides) }

    private func load() {
        services.daemon.send("history-hidden-load") { [weak self] connection in
            let projection = try await connection.frontendProjection(subject: Self.subject)
            guard projection.schemaVersion == HiddenHistory.schemaVersion, projection.projection != .null,
                  let stored = try? JSONDecoder().decode(HiddenHistory.self, from: JSONEncoder().encode(projection.projection)) else { return }
            await MainActor.run { self?.loaded(stored) }
        }
    }
}

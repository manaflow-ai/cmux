import CmuxNextDaemon
import CmuxNextHistory
import Foundation
import Observation

/// The hides of history the app cannot delete (agent sessions and terminal
/// commands in the daemons' append-only journals), kept in the home
/// session's personal projection `history.hidden` (plans/cmux-next/history.md 3).
/// Loaded on connect and merged with hides made before the load; a
/// revision conflict merges both documents, so no clear is lost.
final class HiddenHistoryStore {
    static let subject = "history.hidden"

    private unowned let services: AppServices
    private(set) var document = HiddenHistory()
    private var revision: UInt64?
    private var loaded = false
    private var observation: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
        let store = services.daemon.store
        observation = Task { [weak self] in
            for await connected in Observations({ if case .connected = store.connectionState { true } else { false } }) where connected {
                self?.load()
            }
        }
    }

    deinit { observation?.cancel() }

    func change(_ body: (inout HiddenHistory) -> Void) {
        body(&document)
        save()
    }

    private func load() {
        guard !loaded else { return }
        services.daemon.send("history-hidden-load") { [weak self] connection in
            let projection = try await connection.frontendProjection(subject: Self.subject)
            let stored = projection.schemaVersion == HiddenHistory.schemaVersion && projection.projection != .null
                ? try? JSONDecoder().decode(HiddenHistory.self, from: JSONEncoder().encode(projection.projection)) : nil
            await MainActor.run {
                guard let self else { return }
                self.loaded = true
                self.revision = projection.projectionRevision
                if let stored { self.document = stored.merged(with: self.document) }
            }
        }
    }

    private func save() {
        let document = document
        let revision = revision
        services.daemon.send("history-hidden-save") { [weak self] connection in
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(document))
            do {
                let stored = try await connection.putFrontendProjection(subject: Self.subject, schemaVersion: HiddenHistory.schemaVersion,
                                                                        projection: value, expectedRevision: revision)
                await MainActor.run { self?.revision = stored.projectionRevision }
            } catch DaemonError.command(_, let message, _, _, _) where message.contains("revision conflict") {
                let current = try await connection.frontendProjection(subject: Self.subject)
                let theirs = (try? JSONDecoder().decode(HiddenHistory.self, from: JSONEncoder().encode(current.projection))) ?? HiddenHistory()
                let merged = theirs.merged(with: document)
                let mergedValue = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(merged))
                let stored = try await connection.putFrontendProjection(subject: Self.subject, schemaVersion: HiddenHistory.schemaVersion,
                                                                        projection: mergedValue, expectedRevision: current.projectionRevision)
                await MainActor.run {
                    self?.document = merged
                    self?.revision = stored.projectionRevision
                }
            }
        }
    }
}

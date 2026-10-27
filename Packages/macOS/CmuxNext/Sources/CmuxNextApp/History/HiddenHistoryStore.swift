import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextWakeups
import Foundation
import Observation

/// The hides of history the app cannot delete (agent sessions and terminal
/// commands in the daemons' append-only journals), kept in the home
/// session's personal projection `history.hidden` (plans/cmux-next/history.md 3).
/// Loaded on connect and merged with hides made before the load, which are
/// saved only after it (a save without a revision would replace the stored
/// document, cx-bxh0); a revision conflict merges both documents, so no
/// clear is lost.
final class HiddenHistoryStore {
    static let subject = "history.hidden"

    /// The home daemon (`AppServices.daemon`) the document is kept in, and the app's main-thread scheduler; neither
    /// holds a reference back to the services.
    private let daemon: DaemonService
    private let mainWork: MainWorkScheduler
    private(set) var document = HiddenHistory()
    private var revision: UInt64?
    private var loaded = false
    /// A hide came before the load: the load saves the merge.
    private var savesAfterLoad = false
    /// Loads on each connect. `background`: nobody waits on the hides; a hide made first is kept and merged.
    private var observation: ServiceObservation<Bool>?

    init(services: AppServices) {
        daemon = services.daemon
        mainWork = services.mainWork
        let store = services.daemon.store
        observation = ServiceObservation(.background, owner: "HiddenHistory.connect", on: services.mainWork) {
            if case .connected = store.connectionState { true } else { false }
        } apply: { [weak self] connected in
            if connected { self?.load() }
        }
    }

    func change(_ body: (inout HiddenHistory) -> Void) {
        body(&document)
        guard loaded else {
            savesAfterLoad = true
            load() // a failed load would otherwise hold the hide until the next reconnect
            return
        }
        save()
    }

    private func load() {
        guard !loaded else { return }
        let mainWork = mainWork
        daemon.send("history-hidden-load") { [weak self] connection in
            let projection = try await connection.frontendProjection(subject: Self.subject)
            let stored = projection.schemaVersion == HiddenHistory.schemaVersion && projection.projection != .null
                ? try? JSONDecoder().blockingDecode(HiddenHistory.self, from: JSONEncoder().encode(projection.projection)) : nil
            mainWork.postFromAnyThread(.background, owner: "HiddenHistory.loaded") {
                guard let self else { return }
                self.loaded = true
                self.revision = projection.projectionRevision
                if let stored { self.document = stored.merged(with: self.document) }
                if self.savesAfterLoad {
                    self.savesAfterLoad = false
                    self.save()
                }
            }
        }
    }

    private func save() {
        let document = document
        let revision = revision
        let mainWork = mainWork
        daemon.send("history-hidden-save") { [weak self] connection in
            let value = try JSONDecoder().blockingDecode(JSONValue.self, from: JSONEncoder().encode(document))
            do {
                let stored = try await connection.putFrontendProjection(subject: Self.subject, schemaVersion: HiddenHistory.schemaVersion,
                                                                        projection: value, expectedRevision: revision)
                mainWork.postFromAnyThread(.background, owner: "HiddenHistory.saved") { self?.revision = stored.projectionRevision }
            } catch DaemonError.command(_, let message, _, _, _) where message.contains("revision conflict") {
                let current = try await connection.frontendProjection(subject: Self.subject)
                let theirs = (try? JSONDecoder().blockingDecode(HiddenHistory.self, from: JSONEncoder().encode(current.projection))) ?? HiddenHistory()
                let merged = theirs.merged(with: document)
                let mergedValue = try JSONDecoder().blockingDecode(JSONValue.self, from: JSONEncoder().encode(merged))
                let stored = try await connection.putFrontendProjection(subject: Self.subject, schemaVersion: HiddenHistory.schemaVersion,
                                                                        projection: mergedValue, expectedRevision: current.projectionRevision)
                mainWork.postFromAnyThread(.background, owner: "HiddenHistory.merged") {
                    self?.document = merged
                    self?.revision = stored.projectionRevision
                }
            }
        }
    }
}

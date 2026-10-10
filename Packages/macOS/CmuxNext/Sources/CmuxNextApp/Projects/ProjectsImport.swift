import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation
import os

/// Relays acpmux's chat index into the daemon's project list
/// (plans/cmux-next/projects.md section 3). acpmux already watches the chat
/// roots and `ChatsFeed` mirrors its index, so no second watcher reads them:
/// on each index change this sends one complete `project.observe` per harness
/// whose project set changed. On each new daemon connection it first sends
/// `project.sync`, which makes the daemon reread the editor sources. It holds
/// no rule: refusals, merge and the user's overlay are the daemon's.
@MainActor
final class ProjectsImport {
    /// One harness's projects: each cwd with its newest chat.
    struct Batch: Equatable {
        struct Entry: Equatable {
            let path: String
            let lastUsedMs: Int64
        }

        let source: String
        let entries: [Entry]

        var fingerprint: Int {
            var hasher = Hasher()
            for entry in entries {
                hasher.combine(entry.path)
                hasher.combine(entry.lastUsedMs)
            }
            return hasher.finalize()
        }

        var entriesJSON: [JSONValue] {
            entries.map { .object(["path": .string($0.path), "last_used_ms": .string(String($0.lastUsedMs))]) }
        }
    }

    /// The batches for `chats`, leaving out each harness whose fingerprint is
    /// already `sent`. A harness in `sent` with no chat left gets an empty
    /// complete list. Sorted by harness, entries by path.
    nonisolated static func batches(_ chats: [AcpmuxChat], sent: [String: Int]) -> [Batch] {
        var newest: [String: [String: Int64]] = [:]
        for chat in chats {
            guard let cwd = chat.cwd, cwd.hasPrefix("/") else { continue }
            let used = Int64((chat.updatedAt.timeIntervalSince1970 * 1000).rounded())
            newest[chat.harness, default: [:]][cwd] = max(newest[chat.harness]?[cwd] ?? .min, used)
        }
        for source in sent.keys where newest[source] == nil { newest[source] = [:] }
        return newest.keys.sorted().compactMap { source in
            let entries = (newest[source] ?? [:]).sorted { $0.key < $1.key }.map { Batch.Entry(path: $0.key, lastUsedMs: $0.value) }
            let batch = Batch(source: source, entries: entries)
            return sent[source] == batch.fingerprint ? nil : batch
        }
    }

    private weak var services: AppServices?
    private var connectionID: ObjectIdentifier?
    private var sent: [String: Int] = [:]
    private var sending: Task<Void, Never>?
    private var sendAgain = false
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "projects-import")

    init(services: AppServices) { self.services = services }

    isolated deinit { sending?.cancel() }

    /// Follows the chat index and the local daemon connection for the app's life.
    func start(feed: ChatsFeed?) {
        feed?.observe(self) { [weak self] in self?.relay() }
        armConnection()
        relay()
    }

    private func armConnection() {
        guard let daemon = services?.machines.local else { return }
        withObservationTracking {
            _ = daemon.connection
        } onChange: { [weak self] in
            // task-owner: one hop per connection change, re-arms itself; ends with the relay
            Task { @MainActor [weak self] in
                self?.armConnection()
                self?.relay()
            }
        }
    }

    /// One send at a time; a change during one sends again after it.
    private func relay() {
        guard sending == nil else {
            sendAgain = true
            return
        }
        guard let services, let connection = services.machines.local.connection,
              services.machines.local.supports(DaemonCapabilities.shared.projectList) else { return }
        let id = ObjectIdentifier(connection)
        let fresh = connectionID != id
        if fresh { sent = [:] }
        let batches = Self.batches(services.chatsFeed?.chats ?? [], sent: sent)
        guard fresh || !batches.isEmpty else { return }
        let client = ProjectStateClient(connection: connection)
        sending = Task { [weak self] in
            var delivered: [String: Int] = [:]
            var synced = !fresh
            do {
                if fresh {
                    try await client.sync(existing: [], gone: [], idempotencyKey: UUID().uuidString)
                    synced = true
                }
                for batch in batches {
                    try await client.observe(source: batch.source, entries: batch.entriesJSON, complete: true,
                                             idempotencyKey: UUID().uuidString)
                    delivered[batch.source] = batch.fingerprint
                }
            } catch {
                self?.logger.error("project import failed: \(String(describing: error), privacy: .private)")
            }
            self?.finished(id, synced: synced, delivered: delivered)
        }
    }

    private func finished(_ id: ObjectIdentifier, synced: Bool, delivered: [String: Int]) {
        sending = nil
        if synced { connectionID = id }
        if connectionID == id { sent.merge(delivered) { $1 } }
        if sendAgain {
            sendAgain = false
            relay()
        }
    }
}

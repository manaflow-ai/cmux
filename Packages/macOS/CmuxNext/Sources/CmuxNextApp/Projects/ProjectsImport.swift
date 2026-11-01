import CmuxNextAgentLanes
import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation
import os

/// Relays acpmux's chat index into the daemon's project list
/// (plans/cmux-next/projects.md section 3). acpmux already watches the chat
/// roots and groups its index (`_acpmux/chat_projects`), so no second watcher
/// reads them and the app holds no copy of the index: on each index change
/// (`ChatsFeed`'s signal) this sends one complete `project.observe` per harness
/// whose project set changed. On each new daemon connection it first sends
/// `project.sync`, which makes the daemon reread the editor sources. It holds
/// no rule: refusals, merge and the user's overlay are the daemon's.
@MainActor
final class ProjectsImport {
    /// One harness's projects: each cwd with its newest chat.
    nonisolated struct Batch: Equatable, Sendable {
        nonisolated struct Entry: Equatable, Sendable {
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

    /// The batches for acpmux's grouped `projects`, leaving out each harness whose fingerprint is
    /// already `sent`. A harness in `sent` with no project left gets an empty complete list. Sorted
    /// by harness, entries by path. Nothing while the index is not ready or chats are off: a
    /// partial list sent as complete would drop the harness from its projects.
    nonisolated static func batches(_ projects: AcpmuxChatProjects, sent: [String: Int]) -> [Batch] {
        guard projects.ready, projects.enabled else { return [] }
        var bySource: [String: [Batch.Entry]] = [:]
        for project in projects.projects {
            bySource[project.harness, default: []].append(Batch.Entry(path: project.path, lastUsedMs: project.lastUsedMs))
        }
        for source in sent.keys where bySource[source] == nil { bySource[source] = [] }
        return bySource.keys.sorted().compactMap { source in
            let entries = (bySource[source] ?? []).sorted { $0.path < $1.path }
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

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        sending?.cancel()
    }

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
              services.machines.local.supports(DaemonCapability.projectList.rawValue) else { return }
        let id = ObjectIdentifier(connection)
        let fresh = connectionID != id
        if fresh { sent = [:] }
        // acpmux groups its own index (`_acpmux/chat_projects`): a few rows, read off the main
        // actor, never a walk over every chat here.
        let socket = services.chatsFeed?.socketPath
        let alreadySent = sent
        let client = ProjectStateClient(connection: connection)
        sending = Task { [weak self] in
            var batches: [Batch] = []
            if let socket {
                do {
                    batches = Self.batches(try await AcpmuxChatProjects.read(socketPath: socket), sent: alreadySent)
                } catch {
                    // Nothing is sent (a partial list would drop projects). The next index change or
                    // daemon connection relays again: an event that can make the read succeed.
                    self?.logger.error("project list read failed: \(String(describing: error), privacy: .public)")
                }
            }
            var delivered: [String: Int] = [:]
            var synced = !fresh
            guard fresh || !batches.isEmpty else {
                self?.finished(id, synced: synced, delivered: delivered)
                return
            }
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

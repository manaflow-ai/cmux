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
    private weak var services: AppServices?
    private var connectionID: ObjectIdentifier?
    private var sent: [String: Int] = [:]
    private var sending: Task<Void, Never>?
    private var sendAgain = false
    /// Set by the import suggestions host before the first post-frame relay. This is a one-shot
    /// completion so a later chat-index change does not trigger an unbounded scan stream.
    var onInitialRelay: (() -> Void)?
    private var initialRelayFinished = false
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
            var batches: [AcpmuxChatProjects.Batch] = []
            var indexReady = false
            if let socket {
                do {
                    let projects = try await AcpmuxChatProjects.read(socketPath: socket)
                    batches = projects.batches(sent: alreadySent)
                    indexReady = projects.ready && projects.enabled
                } catch {
                    // Nothing is sent (a partial list would drop projects). The next index change or
                    // daemon connection relays again: an event that can make the read succeed.
                    self?.logger.error("project list read failed: \(String(describing: error), privacy: .public)")
                }
            }
            var delivered: [String: Int] = [:]
            var synced = !fresh
            guard fresh || !batches.isEmpty else {
                self?.finished(id, synced: synced, delivered: delivered, indexReady: indexReady)
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
                indexReady = false
            }
            self?.finished(id, synced: synced, delivered: delivered, indexReady: indexReady)
        }
    }

    private func finished(_ id: ObjectIdentifier, synced: Bool, delivered: [String: Int], indexReady: Bool) {
        sending = nil
        if synced { connectionID = id }
        if connectionID == id { sent.merge(delivered) { $1 } }
        if indexReady, !initialRelayFinished, let current = services?.machines.local.connection, ObjectIdentifier(current) == id {
            initialRelayFinished = true
            onInitialRelay?()
        }
        if sendAgain {
            sendAgain = false
            relay()
        }
    }
}

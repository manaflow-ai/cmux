import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextWakeups
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

    /// The batches for `chats`, leaving out each harness whose fingerprint is
    /// already `sent`. A harness in `sent` with no chat left gets an empty
    /// complete list. Sorted by harness, entries by path. Nothing while the
    /// index is not `complete` (still scanning, or turned off): a partial
    /// list sent as complete would drop the harness from its projects.
    nonisolated static func batches(_ chats: [AcpmuxChat], sent: [String: Int], complete: Bool = true) -> [Batch] {
        guard complete else { return [] }
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

    /// `batches` over a mirror snapshot, off the main actor: it groups every chat (5000+ on a
    /// real Mac) on each index change (cx-9c8m.6).
    @concurrent nonisolated static func batches(of store: AcpmuxChatsStore, sent: [String: Int], complete: Bool) async -> [Batch] {
        batches(store.chats, sent: sent, complete: complete)
    }

    /// Where the projects go: the local daemon's connection (its identity) and the sends over it, off main.
    nonisolated struct Target: Sendable {
        let id: ObjectIdentifier
        let send: @Sendable (_ batches: [Batch], _ fresh: Bool) async -> Sent
    }

    /// What one relay delivered: whether its `project.sync` went (a fresh connection), and each harness's fingerprint.
    nonisolated struct Sent: Sendable {
        var synced: Bool
        var delivered: [String: Int]
    }

    private weak var services: AppServices?
    /// The local daemon as a ``Target`` while it is connected and lists projects; tests pass their own.
    private let target: @MainActor () -> Target?
    /// Runs after each relay's bookkeeping (tests read its class there).
    var onFinished: (@MainActor () -> Void)?
    private var connectionID: ObjectIdentifier?
    private var sent: [String: Int] = [:]
    private var sending: Task<Void, Never>?
    private var sendAgain = false
    /// The local daemon's connection (``armConnection()``).
    private var connectionWatch: FrameObservation<ObjectIdentifier?>?
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "projects-import")

    init(services: AppServices, target: (@MainActor () -> Target?)? = nil) {
        self.services = services
        self.target = target ?? { [weak services] in Self.localDaemon(services) }
    }

    /// `services`' local daemon as a ``Target``, nil while it is away or does not list projects.
    private static func localDaemon(_ services: AppServices?) -> Target? {
        guard let services, let connection = services.machines.local.connection,
              services.machines.local.supports(DaemonCapability.projectList.rawValue) else { return nil }
        let client = ProjectStateClient(connection: connection)
        return Target(id: ObjectIdentifier(connection)) { batches, fresh in await deliver(batches, fresh: fresh, to: client) }
    }

    /// `project.sync` first on a `fresh` connection, then one complete `project.observe` per batch, in order.
    @concurrent private nonisolated static func deliver(_ batches: [Batch], fresh: Bool, to client: ProjectStateClient) async -> Sent {
        var sent = Sent(synced: !fresh, delivered: [:])
        do {
            if fresh {
                try await client.sync(existing: [], gone: [], idempotencyKey: UUID().uuidString)
                sent.synced = true
            }
            for batch in batches {
                try await client.observe(source: batch.source, entries: batch.entriesJSON, complete: true,
                                         idempotencyKey: UUID().uuidString)
                sent.delivered[batch.source] = batch.fingerprint
            }
        } catch {
            logger.error("project import failed: \(String(describing: error), privacy: .private)")
        }
        return sent
    }

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

    /// A new local daemon connection relays again (its `project.sync` first): one `.automation` apply per change,
    /// as the daemon gets the projects with no window on screen.
    private func armConnection() {
        guard connectionWatch == nil, let services else { return }
        let daemon = services.machines.local
        connectionWatch = FrameObservation(owner: "projects.import.connection", delivery: .automation,
                                           on: services.mainWork) { [weak daemon] in
            daemon?.connection.map { ObjectIdentifier($0) }
        } onChange: { [weak self] _ in
            self?.relay()
        }
    }

    /// One send at a time; a change during one sends again after it.
    private func relay() {
        guard sending == nil else {
            sendAgain = true
            return
        }
        guard let services, let target = target() else { return }
        let id = target.id, send = target.send
        let fresh = connectionID != id
        if fresh { sent = [:] }
        let feed = services.chatsFeed
        // A copy-on-write snapshot (O(1) here); the walk over every chat runs off the main actor.
        let store = feed?.store ?? AcpmuxChatsStore()
        let complete = (feed?.isReady ?? false) && (feed?.isEnabled ?? false)
        let alreadySent = sent
        let mainWork = services.mainWork
        // task-owner: awaited at once by `sending` below. Only this task holds the snapshot, so it
        // is released when the batches are ready, not after the sends: a held snapshot would make
        // the next main-actor store change copy all 5000 chats.
        let grouping = Task { @concurrent in await Self.batches(of: store, sent: alreadySent, complete: complete) }
        // R-hop: the grouping and the sends run off main; the bookkeeping is one posted `automation` task (the daemon
        // gets the projects with no window on screen, and no person waits for them).
        sending = Task { @concurrent in
            let batches = await grouping.value
            let ended = fresh || !batches.isEmpty ? await send(batches, fresh) : Sent(synced: true, delivered: [:])
            mainWork.postFromAnyThread(.automation, owner: "ProjectsImport.finished") { [weak self] in
                self?.finished(id, synced: ended.synced, delivered: ended.delivered)
            }
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
        onFinished?()
    }
}

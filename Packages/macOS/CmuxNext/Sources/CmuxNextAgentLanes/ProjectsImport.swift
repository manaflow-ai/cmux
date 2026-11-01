import CmuxNextAgentPane
public import CmuxNextDaemon
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
///
/// A failed relay waits a ``Backoff`` before it runs again: index changes in the
/// wait ride on that one retry, and only a new daemon connection (an event that
/// can make it succeed) retries at once. Without the wait, a failed sync left
/// every later relay fresh, and each chat change sent the sync and every list
/// again (v2.2.10-opt: 5,311 failures in 17 h on a Mac deep in swap).
///
/// It knows no app type: the app passes where the projects go (``Target``), the acpmux socket and
/// the local daemon connection it follows (`AppServices.projectsImport`).
@MainActor
public final class ProjectsImport {
    /// One harness's projects: each cwd with its newest chat.
    public nonisolated struct Batch: Equatable, Sendable {
        public nonisolated struct Entry: Equatable, Sendable {
            public let path: String
            public let lastUsedMs: Int64
        }

        public let source: String
        public let entries: [Entry]

        public var fingerprint: Int {
            var hasher = Hasher()
            for entry in entries {
                hasher.combine(entry.path)
                hasher.combine(entry.lastUsedMs)
            }
            return hasher.finalize()
        }

        public var entriesJSON: [JSONValue] {
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

    /// Where the projects go: the local daemon's connection (its identity) and the sends over it.
    public nonisolated struct Target: Sendable {
        public let id: ObjectIdentifier
        public let send: @Sendable (_ batches: [Batch], _ fresh: Bool) async -> Sent

        public init(id: ObjectIdentifier, send: @escaping @Sendable (_ batches: [Batch], _ fresh: Bool) async -> Sent) {
            self.id = id
            self.send = send
        }

        /// A daemon `connection` that lists projects: `project.sync` and `project.observe` over it.
        @MainActor public init(daemon connection: DaemonConnection) {
            let client = ProjectStateClient(connection: connection)
            self.init(id: ObjectIdentifier(connection)) { batches, fresh in await ProjectsImport.deliver(batches, fresh: fresh, to: client) }
        }
    }

    /// What one relay delivered: whether its `project.sync` went (a fresh connection), each
    /// harness's fingerprint, and whether a request failed.
    public nonisolated struct Sent: Sendable {
        public var synced: Bool
        public var delivered: [String: Int]
        public var failed = false

        public init(synced: Bool, delivered: [String: Int], failed: Bool = false) {
            self.synced = synced
            self.delivered = delivered
            self.failed = failed
        }
    }

    /// The local daemon as a ``Target`` while it is connected and lists projects; tests pass their own.
    private let target: @MainActor () -> Target?
    /// The acpmux socket whose grouped projects are read, nil while there is none.
    private let socketPath: @MainActor () -> String?
    /// The local daemon connection, read inside observation tracking: a change relays again.
    private let connection: @MainActor () -> AnyObject?
    private var connectionID: ObjectIdentifier?
    private var sent: [String: Int] = [:]
    private var sending: Task<Void, Never>?
    private var sendAgain = false
    /// The clock a failed relay's retry waits on; tests pass a manual one.
    private let clock: any Clock<Duration>
    /// The spacing of retries after failures; reset by a success or a new connection.
    private var backoff = Backoff(initial: .seconds(2), maximum: .seconds(300))
    /// The wait before a failed relay's retry, and the connection it failed on.
    private var retry: (connection: ObjectIdentifier, wait: Task<Void, Never>)?
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "projects-import")

    /// - Parameters:
    ///   - target: Where the projects go, nil while the local daemon is away or lists no projects.
    ///   - socketPath: The acpmux socket to read the grouped projects from.
    ///   - connection: The local daemon connection to follow (an observable read).
    ///   - clock: The clock a failed relay's retry waits on.
    public init(target: @escaping @MainActor () -> Target?, socketPath: @escaping @MainActor () -> String?,
                connection: @escaping @MainActor () -> AnyObject?, clock: any Clock<Duration> = ContinuousClock()) {
        self.target = target
        self.socketPath = socketPath
        self.connection = connection
        self.clock = clock
    }

    /// The relay in flight, if any (tests await it).
    var inFlight: Task<Void, Never>? { sending }

    /// The wait before a failed relay's retry, if one is pending (tests await it).
    var pendingRetry: Task<Void, Never>? { retry?.wait }

    /// `project.sync` first on a `fresh` connection, then one complete `project.observe` per batch, in order.
    /// The first failed request ends the relay. On the main actor, as the relay's sends have always run.
    fileprivate static func deliver(_ batches: [Batch], fresh: Bool, to client: ProjectStateClient) async -> Sent {
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
            sent.failed = true
        }
        return sent
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        sending?.cancel()
        retry?.wait.cancel()
    }

    /// Follows the chat index and the local daemon connection for the app's life.
    public func start(feed: ChatsFeed?) {
        feed?.observe(self) { [weak self] in self?.indexChanged() }
        armConnection()
        relay()
    }

    /// The chat index changed.
    func indexChanged() { relay() }

    private func armConnection() {
        withObservationTracking {
            _ = connection()
        } onChange: { [weak self] in
            // task-owner: one hop per connection change, re-arms itself; ends with the relay
            Task { @MainActor [weak self] in
                self?.armConnection()
                self?.relay()
            }
        }
    }

    /// One send at a time; a change during one sends again after it. After a failure, nothing
    /// sends on that connection until its retry wait ends.
    private func relay() {
        guard sending == nil else {
            sendAgain = true
            return
        }
        guard let target = target() else { return }
        let id = target.id, send = target.send
        if let pending = retry {
            // The retry at the end of the wait reads the index as it is then: this change rides on it.
            guard pending.connection != id else { return }
            pending.wait.cancel()
            retry = nil
            backoff.reset()
        }
        let fresh = connectionID != id
        if fresh { sent = [:] }
        // acpmux groups its own index (`_acpmux/chat_projects`): a few rows, read off the main
        // actor, never a walk over every chat here.
        let socket = socketPath()
        let alreadySent = sent
        sending = Task { [weak self] in
            var batches: [Batch] = []
            if let socket {
                do {
                    batches = Self.batches(try await AcpmuxChatProjects.read(socketPath: socket), sent: alreadySent)
                } catch {
                    // Nothing is sent (a partial list would drop projects). The next index change or
                    // daemon connection relays again: an event that can make the read succeed.
                    Self.logger.error("project list read failed: \(String(describing: error), privacy: .public)")
                }
            }
            let ended = fresh || !batches.isEmpty ? await send(batches, fresh) : Sent(synced: !fresh, delivered: [:])
            self?.finished(id, ended)
        }
    }

    private func finished(_ id: ObjectIdentifier, _ ended: Sent) {
        sending = nil
        if ended.synced { connectionID = id }
        if connectionID == id { sent.merge(ended.delivered) { $1 } }
        guard !ended.failed else {
            // Changes during the failed send ride on the retry too.
            sendAgain = false
            scheduleRetry(on: id)
            return
        }
        backoff.reset()
        if sendAgain {
            sendAgain = false
            relay()
        }
    }

    /// Runs the relay again once `backoff`'s next wait ends, with no index change needed.
    private func scheduleRetry(on id: ObjectIdentifier) {
        let start = backoff, clock = clock
        // task-owner: the one retry wait, held in `retry`; a new connection or deinit cancels it.
        let wait = Task { [weak self] in
            var spacing = start
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await spacing.wait(owner: "projects.import.retry", clock: clock) } catch { return }
            guard !Task.isCancelled, let self, self.retry?.connection == id else { return }
            self.backoff = spacing
            self.retry = nil
            self.relay()
        }
        retry = (id, wait)
    }
}

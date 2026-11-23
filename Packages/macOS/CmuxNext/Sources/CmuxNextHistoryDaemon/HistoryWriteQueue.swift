public import CmuxNextDaemon
public import CmuxNextWakeups
import os

private let historyWritesLog = Logger(subsystem: "com.cmuxterm.app.next", category: "history")

/// The daemon history's one ordered queue of writes: every profile's visits, titles and removals and
/// every clear and remove, in the order they were made. A clear made while the local daemon is away
/// therefore reaches it after the visits made before it, so those visits never come back.
///
/// A write waits for a live client (`client`, which returns once the daemon serves history). One that
/// fails because the link dropped under it or its reply never came (`retryable`) stays first and goes
/// again, after a backoff that lets the next connect land, with the same idempotency key (`key`, one per
/// queued write), so the daemon answers a retry of a write it already committed without doing it twice.
/// One whose outcome is unknown in another way (a malformed or undecodable reply: it may have committed)
/// goes again with the same key up to `unknownAttempts` times in all, then is dropped with a log line (the
/// daemon replays the first reply, so a reply that is always malformed must not loop). Only one the daemon
/// answered and refused (`refused`) is done at once. At most `capacity`
/// writes wait; past it the oldest waiting visit goes. A clear or remove is never dropped (else what it
/// removed would come back): with no visit waiting, a new visit is refused instead, and a new clear or
/// remove still goes in, past `capacity` (each one is a person's click, so they stay few).
/// A write that must not wait (a clear with no click-time end) goes through ``sendNow(_:_:done:)`` or not at all.
@MainActor
public final class HistoryWriteQueue<Client: Sendable> {
    /// Sends one write with `key`, the idempotency key every attempt of that write carries.
    public typealias Write = @Sendable (Client, _ key: String) async throws -> Void
    private struct Item {
        let id: UInt64
        let key: String
        let isVisit: Bool
        /// A ``read(_:use:)``: it neither counts toward `capacity` nor makes room.
        let isRead: Bool
        let write: Write
        let done: (@MainActor () -> Void)?
        /// A ``sendNow(_:_:done:)`` write: the client it goes on (never waited for) and its one attempt.
        var now: Client?
    }

    public let capacity: Int
    private var items: [Item] = []
    private var nextID: UInt64 = 0
    /// Queued reads, which `capacity` does not count.
    private var reads = 0
    /// The write being sent (its client is up): never dropped for room, never passed by an `ahead` write.
    private var sending: UInt64?
    private var draining: Task<Void, Never>?
    private let backoff: Backoff
    private let retryable: @Sendable (any Error) -> Bool
    private let refused: @Sendable (any Error) -> Bool
    private let unknownAttempts: Int
    private let client: @MainActor () async -> Client?

    public init(capacity: Int = 4_096, backoff: Backoff = Backoff(initial: .milliseconds(200), maximum: .seconds(5)),
                retryable: @escaping @Sendable (any Error) -> Bool, refused: @escaping @Sendable (any Error) -> Bool = DaemonHistoryClient.isRefusal,
                unknownAttempts: Int = 4, client: @escaping @MainActor () async -> Client?) {
        self.capacity = max(1, capacity)
        self.backoff = backoff
        self.retryable = retryable
        self.refused = refused
        self.unknownAttempts = max(1, unknownAttempts)
        self.client = client
    }

    // The drain holds the queue while it runs; nothing else to stop (#23050: no isolated deinit on a generic class).
    nonisolated deinit {}

    /// Writes not yet sent (the one being sent included).
    public var count: Int { items.count }
    /// Every write but a visit (a clear, a remove, an import) moves it: a ``read(_:use:)`` whose answer may
    /// predate one reads again behind it.
    public private(set) var changes: UInt64 = 0

    /// Queues `write` behind every earlier one (`ahead`: before every waiting one, behind only the one
    /// being sent); `done` runs once it was sent (or refused). A visit refused for room never runs `done`.
    public func enqueue(visit: Bool = false, ahead: Bool = false, _ write: @escaping Write, done: (@MainActor () -> Void)? = nil) {
        if !visit { changes &+= 1 }
        insert(visit: visit, read: false, ahead: ahead, write, done: done)
    }

    /// Sends `write` at once on `client`, the link up now, when nothing is queued or in flight (a read included): it goes
    /// first, then the writes queued after it, so the order holds. It never waits for a client and is tried once; any
    /// failure drops it with a log line. False, with nothing queued, when anything is ahead of it.
    public func sendNow(_ client: Client, _ write: @escaping Write, done: (@MainActor () -> Void)? = nil) -> Bool {
        guard items.isEmpty, draining == nil else { return false }
        changes &+= 1
        nextID += 1
        items.append(Item(id: nextID, key: DaemonHistoryClient.key(), isVisit: false, isRead: false, write: write, done: done, now: client))
        // task-owner: the queue's drain; ends when the queue is empty or the client wait is cancelled
        draining = Task { [weak self] in await self?.drain() }
        return true
    }

    /// Queues `read` behind every earlier write and hands its answer to `use`, unless a clear or remove was
    /// queued meanwhile (``changes`` moved): then it reads again behind that one, so `use` never gets what
    /// a pending or just-queued clear removes (an omnibox seed never brings back a cleared page).
    public func read<Value: Sendable>(_ read: @escaping @Sendable (Client) async throws -> Value,
                                      use: @escaping @MainActor @Sendable (Value) -> Void) {
        let started = changes
        insert(visit: false, read: true, ahead: false, { [weak self] client, _ in
            let value = try await read(client)
            await self?.deliver(value, started: started, read: read, use: use)
        }, done: nil)
    }

    private func deliver<Value: Sendable>(_ value: Value, started: UInt64, read: @escaping @Sendable (Client) async throws -> Value,
                                          use: @escaping @MainActor @Sendable (Value) -> Void) {
        if changes == started { use(value) } else { self.read(read, use: use) }
    }

    private func insert(visit: Bool, read: Bool, ahead: Bool, _ write: @escaping Write, done: (@MainActor () -> Void)?) {
        if !read, items.count - reads >= capacity {
            if let index = items.indices.first(where: { items[$0].isVisit && items[$0].id != sending }) {
                items.remove(at: index)
            } else if visit {
                return
            }
        }
        nextID += 1
        if read { reads += 1 }
        let item = Item(id: nextID, key: DaemonHistoryClient.key(), isVisit: visit, isRead: read, write: write, done: done)
        if ahead {
            // Never before a ``sendNow(_:_:done:)`` write: it was first when it went in and goes first.
            items.insert(item, at: items.firstIndex { $0.id != sending && $0.now == nil } ?? items.endIndex)
        } else {
            items.append(item)
        }
        guard draining == nil else { return }
        // task-owner: the queue's drain; ends when the queue is empty or the client wait is cancelled
        draining = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        defer { draining = nil }
        var backoff = self.backoff
        // The first write's failures of unknown outcome so far.
        var unknown: (id: UInt64, count: Int)?
        while !items.isEmpty {
            // The first write is picked only once the client is up: one queued `ahead` meanwhile goes first. A
            // ``sendNow(_:_:done:)`` write is always first and goes on its own client, with no wait.
            let up: Client?
            if let now = items.first?.now { up = now } else { up = await client() }
            guard let item = items.first, let client = item.now ?? up else { return }
            sending = item.id
            do {
                try await item.write(client, item.key)
            } catch where item.now != nil {
                // Sent at the click, once: a retry could land after newer activity.
                historyWritesLog.error("history write sent at the click dropped, not retried: \(String(describing: error), privacy: .public)")
            } catch where retryable(error) {
                // The link dropped under the write or its reply never came: it goes again (same key) on the next connect.
                sending = nil
                // concurrency-allow: Backoff.wait is an async clock sleep (the task suspends, no thread blocks), once per failed send
                do { try await backoff.wait(owner: "history.writes") } catch { return }
                continue
            } catch where !refused(error) {
                // The outcome is unknown (it may have committed): again with the same key, a bounded number of times.
                let count = (unknown.flatMap { $0.id == item.id ? $0.count : nil } ?? 0) + 1
                unknown = (item.id, count)
                if count < unknownAttempts {
                    sending = nil
                    // concurrency-allow: Backoff.wait is an async clock sleep (the task suspends, no thread blocks), at most unknownAttempts per write
                    do { try await backoff.wait(owner: "history.writes") } catch { return }
                    continue
                }
                historyWritesLog.error("history write dropped after \(count, privacy: .public) unknown outcomes: \(String(describing: error), privacy: .public)")
            } catch {
                // The daemon answered and refused it: a retry changes nothing.
            }
            unknown = nil
            backoff.reset()
            sending = nil
            items.removeAll { $0.id == item.id }
            if item.isRead { reads -= 1 }
            item.done?()
        }
    }
}

extension DaemonHistoryClient {
    /// Whether the daemon answered and refused a write (a `cmux.protocol/2` error it does not ask to retry):
    /// the only failure that ends a write at once. Any other failure that is not a link drop leaves the
    /// outcome unknown (a malformed or undecodable reply may follow a commit).
    public nonisolated static func isRefusal(_ error: any Error) -> Bool {
        if case .command(_, _, _, _, let retryable)? = error as? DaemonError { return retryable != true }
        return false
    }

    /// Whether a write failed because the link dropped under it, its reply never came (`timedOut`: it may
    /// or may not have committed; the retry's same key makes that safe) or the daemon asks for a retry, so
    /// it goes again on the next connect, with no bound.
    public nonisolated static func isLinkDrop(_ error: any Error) -> Bool {
        switch error as? DaemonError {
        case .notConnected?, .connectionClosed?, .daemonShutdown?, .connectFailed?, .timedOut?: true
        case .command(_, _, _, _, let retryable)?: retryable == true
        default: false
        }
    }
}

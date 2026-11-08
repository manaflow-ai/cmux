public import CmuxNextDaemon
public import CmuxNextWakeups

/// The daemon history's one ordered queue of writes: every profile's visits, titles and removals and
/// every clear and remove, in the order they were made. A clear made while the local daemon is away
/// therefore reaches it after the visits made before it, so those visits never come back.
///
/// A write waits for a live client (`client`, which returns once the daemon serves history). One that
/// fails because the link dropped under it or its reply never came (`retryable`) stays first and goes
/// again, after a backoff that lets the next connect land, with the same idempotency key (`key`, one per
/// queued write), so the daemon answers a retry of a write it already committed without doing it twice.
/// One the daemon answered and refused is done. At most `capacity`
/// writes wait; past it the oldest waiting visit goes. A clear or remove is never dropped (else what it
/// removed would come back): with no visit waiting, a new visit is refused instead, and a new clear or
/// remove still goes in, past `capacity` (each one is a person's click, so they stay few).
@MainActor
public final class HistoryWriteQueue<Client: Sendable> {
    /// Sends one write with `key`, the idempotency key every attempt of that write carries.
    public typealias Write = @Sendable (Client, _ key: String) async throws -> Void
    private struct Item {
        let id: UInt64
        let key: String
        let isVisit: Bool
        let write: Write
        let done: (@MainActor () -> Void)?
    }

    public let capacity: Int
    private var items: [Item] = []
    private var nextID: UInt64 = 0
    /// The write being sent (its client is up): never dropped for room, never passed by an `ahead` write.
    private var sending: UInt64?
    private var draining: Task<Void, Never>?
    private let backoff: Backoff
    private let retryable: @Sendable (any Error) -> Bool
    private let client: @MainActor () async -> Client?

    public init(capacity: Int = 4_096, backoff: Backoff = Backoff(initial: .milliseconds(200), maximum: .seconds(5)),
                retryable: @escaping @Sendable (any Error) -> Bool, client: @escaping @MainActor () async -> Client?) {
        self.capacity = max(1, capacity)
        self.backoff = backoff
        self.retryable = retryable
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
        insert(visit: visit, ahead: ahead, write, done: done)
    }

    /// Queues `read` behind every earlier write and hands its answer to `use`, unless a clear or remove was
    /// queued meanwhile (``changes`` moved): then it reads again behind that one, so `use` never gets what
    /// a pending or just-queued clear removes (an omnibox seed never brings back a cleared page).
    public func read<Value: Sendable>(_ read: @escaping @Sendable (Client) async throws -> Value,
                                      use: @escaping @MainActor @Sendable (Value) -> Void) {
        let started = changes
        insert(visit: false, ahead: false, { [weak self] client, _ in
            let value = try await read(client)
            await self?.deliver(value, started: started, read: read, use: use)
        }, done: nil)
    }

    private func deliver<Value: Sendable>(_ value: Value, started: UInt64, read: @escaping @Sendable (Client) async throws -> Value,
                                          use: @escaping @MainActor @Sendable (Value) -> Void) {
        if changes == started { use(value) } else { self.read(read, use: use) }
    }

    private func insert(visit: Bool, ahead: Bool, _ write: @escaping Write, done: (@MainActor () -> Void)?) {
        if items.count >= capacity {
            if let index = items.indices.first(where: { items[$0].isVisit && items[$0].id != sending }) {
                items.remove(at: index)
            } else if visit {
                return
            }
        }
        nextID += 1
        let item = Item(id: nextID, key: DaemonHistoryClient.key(), isVisit: visit, write: write, done: done)
        if ahead {
            items.insert(item, at: items.firstIndex { $0.id != sending } ?? items.endIndex)
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
        while !items.isEmpty {
            // The first write is picked only once the client is up: one queued `ahead` meanwhile goes first.
            guard let client = await client() else { return }
            guard let item = items.first else { return }
            sending = item.id
            do {
                try await item.write(client, item.key)
            } catch where retryable(error) {
                // The link dropped under the write or its reply never came: it goes again (same key) on the next connect.
                sending = nil
                // concurrency-allow: Backoff.wait is an async clock sleep (the task suspends, no thread blocks), once per failed send
                do { try await backoff.wait(owner: "history.writes") } catch { return }
                continue
            } catch {
                // The daemon answered and refused it: a retry changes nothing.
            }
            backoff.reset()
            sending = nil
            items.removeAll { $0.id == item.id }
            item.done?()
        }
    }
}

extension DaemonHistoryClient {
    /// Whether a write failed because the link dropped under it, its reply never came (`timedOut`: it may
    /// or may not have committed; the retry's same key makes that safe) or the daemon asks for a retry, so
    /// it goes again on the next connect; any other answer was the daemon's own refusal.
    public nonisolated static func isLinkDrop(_ error: any Error) -> Bool {
        switch error as? DaemonError {
        case .notConnected?, .connectionClosed?, .daemonShutdown?, .connectFailed?, .timedOut?: true
        case .command(_, _, _, _, let retryable)?: retryable == true
        default: false
        }
    }
}

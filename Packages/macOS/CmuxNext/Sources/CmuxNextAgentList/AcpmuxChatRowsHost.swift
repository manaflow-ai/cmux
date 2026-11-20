public import Foundation
import CmuxNextCompat

/// The pane's host for a chat's rows (the design doc's host contract): one acpmux v2 client handle
/// naming `["chat"]` on a connection of its own to this machine's daemon, the page's five
/// `chat.rows.*` operations, and one call into the page per batch of the core's changes.
///
/// It is glue. The core's bytes go to the page as they are, framed by ``AcpmuxClientByteConnection``
/// (one batch out at a time, at most ``maxBatchBytes`` unless it is one change); the host reads a
/// change's `kind` (a `fallback` closes the connection) and nothing else. It runs no timer for
/// rows: the page's `taken` is the acknowledgement and the only pacer. Hidden, it hands no batch
/// and acknowledges none, so the driver reads no more and the daemon's credit holds the sub. When
/// the page is gone the host ends its sids, closes the connection and lets the handle go; a later
/// open makes a new one. Every operation and batch runs on one utility queue, off the main actor.
public nonisolated final class AcpmuxChatRowsHost: Sendable {
    /// A pane's batch: the page must take a push inside a 4 ms slice of the thread a key waits on.
    public static let maxBatchBytes = 64 << 10
    /// The most chat subs one pane holds.
    public static let maxSubs = 16

    /// The page's refusal codes.
    public enum Refusal: String, Error, Sendable {
        /// No client at all (no wrapper, an ABI mismatch): the page runs v1 for the chat.
        case off = "chat.rows.off"
        /// The core refused the page or blob now: one page is out, or the first window has not come.
        case busy = "chat.rows.busy"
        /// The pane holds ``maxSubs`` subs.
        case limit = "chat.rows.limit"
        /// A name of another shape, one the handle holds, or a sid this page did not open.
        case name = "chat.rows.name"
    }

    /// What the host has done (tests and the bench): every queue turn it ran (`wakeups`), each
    /// batch the driver handed it, each call into the page, each timer it armed.
    struct Counters: Sendable, Equatable {
        var wakeups = 0
        var batchesIn = 0
        var bridgeCalls = 0
        var timersArmed = 0
    }

    /// How a driver starts and reopens (tests replace it with the driver's feed seam).
    struct Connector: Sendable {
        var start: @Sendable (AcpmuxClientByteConnection, String, @escaping @Sendable (Data) -> Void,
                              @escaping @Sendable () -> Void) -> Void
        var reconnect: @Sendable (AcpmuxClientByteConnection, String, @escaping @Sendable () -> Void) -> Void

        static let socket = Connector(
            start: { driver, path, onChange, onClose in driver.start(path: path, onChange: onChange, onClose: onClose) },
            reconnect: { driver, path, refused in driver.reconnect(path: path, refused: refused) })
    }

    private struct State {
        var client: AcpmuxClient?
        var driver: AcpmuxClientByteConnection?
        var sids: Set<String> = []
        var hidden = false
        /// The batch the page has and has not taken, and the driver it came from.
        var outstanding: (batch: Int, driver: AcpmuxClientByteConnection)?
        /// A batch the driver handed over that waits for the page (hidden, or one is out).
        var held: (bytes: Data, driver: AcpmuxClientByteConnection)?
        /// A batch the page took while hidden: acknowledged when the pane shows.
        var ackOwed: AcpmuxClientByteConnection?
        var nextBatch = 1
        var backoff: Double = AcpmuxChatRowsHost.firstBackoff
        var reconnecting = false
        var counters = Counters()
    }

    static let firstBackoff = 0.25
    static let lastBackoff = 8.0
    private let queue = DispatchQueue(label: "cmux.acpmux-chat-rows", qos: .utility) // qos-allow: a chat's rows are background transport work; the page's call hops to main once per batch
    private let state = Mutex(State())
    private let socketPath: String
    private let deliver: @Sendable (String) -> Void
    private let makeClient: @Sendable () -> AcpmuxClient
    private let connector: Connector

    /// - Parameters:
    ///   - socketPath: The pane's own daemon socket on this machine.
    ///   - deliver: Runs the page's call for one batch; called off the main actor, once a batch.
    public convenience init(socketPath: String, deliver: @escaping @Sendable (String) -> Void) {
        self.init(socketPath: socketPath, deliver: deliver, makeClient: { AcpmuxClient(surfaces: ["chat"]) }, connector: .socket)
    }

    init(socketPath: String, deliver: @escaping @Sendable (String) -> Void,
         makeClient: @escaping @Sendable () -> AcpmuxClient, connector: Connector) {
        self.socketPath = socketPath
        self.deliver = deliver
        self.makeClient = makeClient
        self.connector = connector
    }

    /// `chat.rows.open`: subscribes `request` (`{sid, chat, anchor?, window?}`, passed to the core as
    /// it is) under the page's `sid`. The caller has checked that the chat is the pane's.
    public func open(sid: String, request: Data) async -> Result<String, Refusal> {
        await run { [self] (state: inout State) -> Result<String, Refusal> in
            guard AcpmuxChatRowsBatch.isName(sid), !state.sids.contains(sid) else { return .failure(.name) }
            guard state.sids.count < Self.maxSubs else { return .failure(.limit) }
            if state.client == nil {
                let client = makeClient()
                guard client.isAvailable else { return .failure(.off) }
                state.client = client
            }
            guard let client = state.client, client.subscribeChat(request) != nil else { return .failure(.name) }
            state.sids.insert(sid)
            if state.driver == nil, !state.reconnecting { startDriver(&state, client: client) }
            return .success(sid)
        }
    }

    /// `chat.rows.close`: ends a sid this page opened (`unsub` on the wire).
    public func close(sid: String) async -> Result<Void, Refusal> {
        await run { (state: inout State) -> Result<Void, Refusal> in
            guard state.sids.remove(sid) != nil else { return .failure(.name) }
            state.client?.unsubscribe(Self.sidRequest(sid))
            return .success(())
        }
    }

    /// `chat.rows.page`: asks the core for a page of `sid` (`request` as the page sent it).
    public func page(sid: String, request: Data) async -> Result<Void, Refusal> {
        await run { (state: inout State) -> Result<Void, Refusal> in
            guard state.sids.contains(sid), let client = state.client else { return .failure(.name) }
            return client.chatPage(request) == 0 ? .success(()) : .failure(.busy)
        }
    }

    /// `chat.rows.blob`: asks for a range of a row's body or a prompt's text under the page's `id`.
    public func blob(sid: String, id: String, request: Data) async -> Result<String, Refusal> {
        await run { (state: inout State) -> Result<String, Refusal> in
            guard state.sids.contains(sid), AcpmuxChatRowsBatch.isName(id), let client = state.client else { return .failure(.name) }
            return client.chatBlob(request) != nil ? .success(id) : .failure(.busy)
        }
    }

    /// `chat.rows.taken`: the page applied batch `number`. The driver reads on, and a held batch
    /// goes, unless the pane is hidden.
    public func taken(batch number: Int) {
        queue.async { [self] in
            state.withLock { state in
                state.counters.wakeups += 1
                guard let out = state.outstanding, out.batch == number else { return }
                state.outstanding = nil
                if out.driver === state.driver {
                    if state.hidden { state.ackOwed = out.driver } else { out.driver.acknowledgeBatch() }
                }
                deliverHeld(&state)
            }
        }
    }

    /// Whether nobody can see the pane. Shown again, a batch taken while hidden is acknowledged and
    /// a held one goes.
    public func setHidden(_ hidden: Bool) {
        queue.async { [self] in
            state.withLock { state in
                state.counters.wakeups += 1
                guard state.hidden != hidden else { return }
                state.hidden = hidden
                guard !hidden else { return }
                if let owed = state.ackOwed, owed === state.driver { owed.acknowledgeBatch() }
                state.ackOwed = nil
                deliverHeld(&state)
            }
        }
    }

    /// The pane's page is gone (hibernated, reset, closed): every sid it opened ends (`unsub`), the
    /// connection closes and the handle is let go. The next document opens again.
    public func pageGone() {
        queue.async { [self] in
            state.withLock { state in
                state.counters.wakeups += 1
                if let client = state.client {
                    for sid in state.sids.sorted() { client.unsubscribe(Self.sidRequest(sid)) }
                }
                state.driver?.stop()
                let counters = state.counters
                state = State()
                state.counters = counters
            }
        }
    }

    // MARK: Batches

    private func startDriver(_ state: inout State, client: AcpmuxClient) {
        let driver = AcpmuxClientByteConnection(client: client, maxBatchBytes: Self.maxBatchBytes, framesChanges: true)
        state.driver = driver
        let id = ObjectIdentifier(driver)
        connector.start(driver, socketPath, { [weak self] batch in self?.received(batch, from: id) },
                        { [weak self] in self?.dropped(id) })
    }

    /// A batch from the driver, on the driver's queue: hands it to the page now, or holds it.
    private func received(_ batch: Data, from id: ObjectIdentifier) {
        queue.async { [self] in
            state.withLock { state in
                state.counters.wakeups += 1
                guard let driver = state.driver, ObjectIdentifier(driver) == id else { return }
                state.counters.batchesIn += 1
                state.backoff = Self.firstBackoff
                state.held = (batch, driver)
                deliverHeld(&state)
            }
        }
    }

    private func deliverHeld(_ state: inout State) {
        guard !state.hidden, state.outstanding == nil, let held = state.held else { return }
        state.held = nil
        var changes = AcpmuxChatRowsBatch.changes(inFramed: held.bytes) ?? []
        let fallback = changes.contains { AcpmuxChatRowsBatch.kind(of: $0) == "fallback" }
        if fallback { changes.removeAll { AcpmuxChatRowsBatch.kind(of: $0) == "fallback" } }
        if changes.isEmpty {
            if !fallback { held.driver.acknowledgeBatch() }
        } else {
            let number = state.nextBatch
            state.nextBatch += 1
            state.outstanding = (number, held.driver)
            state.counters.bridgeCalls += 1
            deliver(AcpmuxChatRowsBatch.script(batch: number, changes: changes))
        }
        guard fallback else { return }
        // The daemon answered as v1 or grants no `chat`: each sid got its `chatError` in this
        // batch. The connection closes; the next open makes a new handle and upgrades again.
        held.driver.stop()
        state.driver = nil
        state.client = nil
        state.sids.removeAll()
    }

    /// The socket dropped: no event to the page. The same handle reconnects after a backoff and
    /// the core's resume gives what was missed; with no sid open the handle is let go instead.
    private func dropped(_ id: ObjectIdentifier) {
        queue.async { [self] in
            state.withLock { state in
                state.counters.wakeups += 1
                guard let driver = state.driver, ObjectIdentifier(driver) == id else { return }
                guard !state.sids.isEmpty else {
                    state.driver = nil
                    state.client = nil
                    return
                }
                state.reconnecting = true
                state.counters.timersArmed += 1
                let delay = state.backoff
                state.backoff = min(state.backoff * 2, Self.lastBackoff)
                // concurrency-allow: the reconnect backoff runs on this host's utility queue, never main; armed once per drop, at most 8 s
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reconnect(id) }
            }
        }
    }

    private func reconnect(_ id: ObjectIdentifier) {
        state.withLock { state in
            state.counters.wakeups += 1
            guard let driver = state.driver, ObjectIdentifier(driver) == id else { return }
            state.reconnecting = false
            connector.reconnect(driver, socketPath) { [weak self] in self?.replace(id) }
        }
    }

    /// The driver could not reopen (it failed on bad bytes): a new one on the same handle.
    private func replace(_ id: ObjectIdentifier) {
        queue.async { [self] in
            state.withLock { state in
                state.counters.wakeups += 1
                guard let driver = state.driver, ObjectIdentifier(driver) == id, let client = state.client else { return }
                if state.outstanding?.driver === driver { state.outstanding = nil }
                state.held = nil
                startDriver(&state, client: client)
            }
        }
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (inout State) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let value = state.withLock { state in
                    state.counters.wakeups += 1
                    return body(&state)
                }
                continuation.resume(returning: value)
            }
        }
    }

    private static func sidRequest(_ sid: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["sid": sid])) ?? Data()
    }

    // MARK: Tests

    /// The counters, the client and the driver now (tests), read on the host's queue.
    func snapshotForTesting() async -> (counters: Counters, client: AcpmuxClient?, driver: AcpmuxClientByteConnection?, sids: Set<String>) {
        await run { (state: inout State) -> (counters: Counters, client: AcpmuxClient?, driver: AcpmuxClientByteConnection?, sids: Set<String>) in
            state.counters.wakeups -= 1
            return (state.counters, state.client, state.driver, state.sids)
        }
    }
}

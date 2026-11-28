public import Foundation
import CmuxNextCompat

/// The pane's host for a chat's rows (the design doc's host contract): one acpmux v2 client handle
/// naming `["chat"]` on a connection of its own to this machine's daemon, the page's five
/// `chat.rows.*` operations, and one call into the page per batch of the core's changes.
///
/// It is glue. The core's bytes go to the page as they are, framed by ``AcpmuxClientByteConnection``
/// (one batch out at a time, at most ``maxBatchBytes`` unless it is one change); the host reads a
/// change's `kind` (a `fallback` closes the connection, a change other than a `chatOp` is one the
/// page waits on) and nothing else. Shown, the page's `taken` is the acknowledgement and the only
/// pacer; a batch untaken after ``ackWait`` goes again under its number (doubling to
/// ``lastAckWait``), so one lost call or `taken` never stops the chat's rows. Hidden (a covered
/// or minimized window, another tab), it paces as v1's pacer does for a pane nobody sees: a batch
/// the page waits on (a window, a page, a blob, an error) goes at once, and ops go at most every ``hiddenInterval``, on one deadline, while the daemon's credit holds
/// the rest. A chat started in a covered window draws its rows and its turn's end (cmux#44964);
/// holding every batch left it on Thinking with no row while acpmux had the answer. When
/// the page is gone the host ends its sids, closes the connection and lets the handle go; a later
/// open makes a new one. Every operation and batch runs on one utility queue, off the main actor.
public nonisolated final class AcpmuxChatRowsHost: Sendable {
    /// A pane's batch: the page must take a push inside a 4 ms slice of the thread a key waits on.
    public static let maxBatchBytes = 64 << 10
    /// The most chat subs one pane holds.
    public static let maxSubs = 16
    /// Shortest time between two calls with only ops in them to a page nobody can see: a hidden
    /// streaming chat wakes its web process at most once a second, and its turn's end shows.
    public static let hiddenInterval: TimeInterval = 1

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
        /// The core refused the sub request itself (an anchor or window of another shape, a chat
        /// id over the wire's limit): the code the page route gives any malformed params.
        case request = "cmux.protocol.invalid_params"
    }

    /// What the host has done (tests and the bench): every queue turn it ran (`wakeups`), each
    /// batch the driver handed it, each call into the page, each timer it armed.
    struct Counters: Sendable, Equatable {
        var wakeups = 0
        var batchesIn = 0
        var bridgeCalls = 0
        var timersArmed = 0
        /// Ack deadlines armed, and batches sent again because their `taken` never came.
        var ackDeadlines = 0
        var resends = 0
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

    /// A batch out to the page: its number, the driver it came from (nil: a carried batch, which
    /// owes no driver an ack), the JSON text that carried it (resent as it is: the same number), and
    /// when it goes again untaken.
    private struct Outstanding {
        var batch: Int
        var driver: AcpmuxClientByteConnection?
        var batchText: String
        /// How long the page has from the last send (``ackWait``, doubled each send to ``lastAckWait``).
        var wait: TimeInterval
        /// Uptime nanoseconds when ``wait`` runs out.
        var deadline: UInt64
    }

    private struct State {
        var client: AcpmuxClient?
        var driver: AcpmuxClientByteConnection?
        var sids: Set<String> = []
        var hidden = false
        /// The batch the page has and has not taken.
        var outstanding: Outstanding?
        /// A deadline is out for ``outstanding``: one at a time, and none once every batch is taken.
        var ackDeadlineArmed = false
        /// A batch the driver handed over that waits for the page (hidden, or one is out).
        var held: (bytes: Data, driver: AcpmuxClientByteConnection)?
        /// A held batch whose driver was replaced. The core already gave these changes, so they
        /// go to the page before anything the new driver hands over, and no driver is owed an ack.
        var carried: Data?
        /// The last call into the page, as uptime nanoseconds (the hidden pace).
        var lastCall: UInt64 = 0
        /// A hidden page's ops wait out ``hiddenInterval`` on the deadline.
        var waitingWhileHidden = false
        /// Bumped when the page goes: a deadline armed for an earlier page does nothing.
        var generation = 0
        var nextBatch = 1
        var backoff: Double = AcpmuxChatRowsHost.firstBackoff
        var reconnecting = false
        var counters = Counters()
    }

    static let firstBackoff = 0.25
    static let lastBackoff = 8.0
    /// How long the page has to take a batch before the host sends it again, under the same number.
    /// A shown page takes one in a frame or a few. A call that never ran, a page that never got it
    /// or a `taken` that was lost otherwise held the chat's rows until the pane was reopened; the
    /// page applies a batch number once and takes a repeat again (rows/receiver.ts).
    public static let ackWait: TimeInterval = 2
    /// The longest wait between two sends of one untaken batch (a page that cannot draw yet).
    public static let lastAckWait: TimeInterval = 30
    private let queue = DispatchQueue(label: "cmux.acpmux-chat-rows", qos: .utility) // qos-allow: a chat's rows are background transport work; the page's call hops to main once per batch
    private let state = Mutex(State())
    private let socketPath: String
    private let deliver: @Sendable (String) -> Void
    /// The page's fixed call for every batch; `deliver`'s text is its `batch` argument.
    public static let receiveBody = AcpmuxChatRowsBatch.receiveBody
    private let makeClient: @Sendable () -> AcpmuxClient
    private let connector: Connector
    /// ``hiddenInterval``, or a test's own.
    private let hiddenPace: TimeInterval
    /// ``ackWait``, or a test's own.
    private let firstAckWait: TimeInterval

    /// - Parameters:
    ///   - socketPath: The pane's own daemon socket on this machine.
    ///   - deliver: Runs the page's call for one batch, given the batch's JSON text
    ///     (``AcpmuxChatRowsBatch/argument(batch:changes:)``), as the `batch` argument of the fixed
    ///     ``AcpmuxChatRowsBatch/receiveBody``; called off the main actor, once a batch.
    public convenience init(socketPath: String, deliver: @escaping @Sendable (String) -> Void) {
        self.init(socketPath: socketPath, deliver: deliver, makeClient: { AcpmuxClient(surfaces: ["chat"]) }, connector: .socket)
    }

    init(socketPath: String, deliver: @escaping @Sendable (String) -> Void,
         makeClient: @escaping @Sendable () -> AcpmuxClient, connector: Connector,
         hiddenInterval: TimeInterval = AcpmuxChatRowsHost.hiddenInterval,
         ackWait: TimeInterval = AcpmuxChatRowsHost.ackWait) {
        self.socketPath = socketPath
        self.hiddenPace = hiddenInterval
        self.firstAckWait = ackWait
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
            guard let client = state.client else { return .failure(.off) }
            if let refusal = Self.subscribeRefusal(client.subscribeChatCode(request)) { return .failure(refusal) }
            state.sids.insert(sid)
            if state.driver == nil, !state.reconnecting { startDriver(&state, client: client) }
            return .success(sid)
        }
    }

    /// The page's code for the core's answer to `subscribe_chat`, or nil when it took the sub.
    /// The core refuses a sid of another shape, one it holds, a 257th sub, an anchor or request of
    /// another shape and a chat id over the wire's limit, all as `ERR_INVALID`; the first three
    /// never reach it (``open(sid:request:)`` refuses them as `name` and `limit` first), so what
    /// is left is the request. No handle (`ERR_NULL`, `ERR_UNKNOWN`) or a panic in the core
    /// (`ERR_PANIC`) is no client: `off`.
    static func subscribeRefusal(_ code: Int32) -> Refusal? {
        switch code {
        case 0: nil
        case AcpmuxClient.refusedCode: .request
        default: .off
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

    /// `chat.rows.heights.read`: returns remembered exact measurements for this open sid.
    public func rowHeightsRead(sid: String, request: Data) async -> Result<Data, Refusal> {
        await run { (state: inout State) -> Result<Data, Refusal> in
            guard state.sids.contains(sid), let client = state.client else { return .failure(.name) }
            guard let response = client.rowHeightsRead(request) else { return .failure(.busy) }
            return .success(response)
        }
    }

    /// `chat.rows.heights.write`: stores page measurements for this open sid.
    public func rowHeightsWrite(sid: String, request: Data) async -> Result<Data, Refusal> {
        await run { (state: inout State) -> Result<Data, Refusal> in
            guard state.sids.contains(sid), let client = state.client else { return .failure(.name) }
            guard let response = client.rowHeightsWrite(request) else { return .failure(.busy) }
            return .success(response)
        }
    }

    /// `chat.rows.taken`: the page applied batch `number`. The driver reads on, and a held batch
    /// goes (hidden, at the hidden pace).
    public func taken(batch number: Int) {
        queue.async { [self] in
            state.withLock { state in
                state.counters.wakeups += 1
                guard let out = state.outstanding, out.batch == number else { return }
                state.outstanding = nil
                // Acknowledged hidden too: the pace is the next call's, so the sub reads on.
                if let driver = out.driver, driver === state.driver { driver.acknowledgeBatch() }
                deliverHeld(&state)
            }
        }
    }

    /// Whether nobody can see the pane. Shown again, a held batch goes.
    public func setHidden(_ hidden: Bool) {
        queue.async { [self] in
            state.withLock { state in
                state.counters.wakeups += 1
                guard state.hidden != hidden else { return }
                state.hidden = hidden
                guard !hidden else { return }
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
                let generation = state.generation
                state = State()
                state.counters = counters
                state.generation = generation &+ 1
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
        guard state.outstanding == nil else { return }
        let next: (bytes: Data, driver: AcpmuxClientByteConnection?)
        if let carried = state.carried {
            next = (carried, nil)
        } else if let held = state.held {
            next = (held.bytes, held.driver)
        } else {
            return
        }
        var changes = AcpmuxChatRowsBatch.changes(inFramed: next.bytes) ?? []
        // Hidden, ops wait out the hidden pace; a batch the page waits on (or an empty one) goes at
        // once, even while a deadline armed earlier is still out. Shown, nothing waits.
        if state.hidden, !changes.isEmpty, !changes.contains(where: { AcpmuxChatRowsBatch.kind(of: $0) != "chatOp" }) {
            if state.waitingWhileHidden { return }
            let since = DispatchTime.now().uptimeNanoseconds &- state.lastCall
            let interval = UInt64(hiddenPace * 1e9)
            if state.lastCall != 0, since < interval {
                state.waitingWhileHidden = true
                state.counters.timersArmed += 1
                let generation = state.generation
                // concurrency-allow: the hidden pace runs on this host's utility queue, never main; one deadline at a time, at most hiddenInterval
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(interval - since))) { [weak self] in self?.hiddenIntervalPassed(generation) }
                return
            }
        }
        if state.carried != nil { state.carried = nil } else { state.held = nil }
        let fallback = changes.contains { AcpmuxChatRowsBatch.kind(of: $0) == "fallback" }
        if fallback { changes.removeAll { AcpmuxChatRowsBatch.kind(of: $0) == "fallback" } }
        if changes.isEmpty {
            if !fallback {
                next.driver?.acknowledgeBatch()
                deliverHeld(&state)
                return
            }
        } else {
            let number = state.nextBatch
            state.nextBatch += 1
            let batch = AcpmuxChatRowsBatch.argument(batch: number, changes: changes)
            let now = DispatchTime.now().uptimeNanoseconds
            state.outstanding = Outstanding(batch: number, driver: next.driver, batchText: batch, wait: firstAckWait,
                                            deadline: now &+ Self.nanoseconds(firstAckWait))
            state.counters.bridgeCalls += 1
            state.lastCall = now
            deliver(batch)
            armAckDeadline(&state)
        }
        guard fallback else { return }
        // The daemon answered as v1 or grants no `chat`: each sid got its `chatError` in this
        // batch. The connection closes; the next open makes a new handle and upgrades again.
        state.driver?.stop()
        state.driver = nil
        state.client = nil
        state.held = nil
        state.sids.removeAll()
    }

    /// A hidden page's ops waited out ``hiddenInterval``: the held batch goes (shown sooner, it went then).
    private func hiddenIntervalPassed(_ generation: Int) {
        state.withLock { state in
            state.counters.wakeups += 1
            // Armed for a page that has gone since: that page's state went with it.
            guard state.generation == generation else { return }
            state.waitingWhileHidden = false
            deliverHeld(&state)
        }
    }

    /// Arms the one deadline for the batch out, at its ``Outstanding/deadline``. A batch taken in
    /// time leaves the deadline nothing to do, and it arms no other: a stream costs at most one
    /// wakeup an ``ackWait``, an idle chat none.
    private func armAckDeadline(_ state: inout State) {
        guard !state.ackDeadlineArmed, let out = state.outstanding else { return }
        state.ackDeadlineArmed = true
        state.counters.ackDeadlines += 1
        let generation = state.generation
        let left = out.deadline &- min(out.deadline, DispatchTime.now().uptimeNanoseconds)
        // concurrency-allow: the ack deadline runs on this host's utility queue, never main; one at a time, only while a batch is out, at most lastAckWait
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(left))) { [weak self] in self?.ackDeadlinePassed(generation) }
    }

    /// The deadline for the batch out passed. Still untaken, the page gets the same call again
    /// (same number, so the page applies it once) and twice as long, up to ``lastAckWait``; a
    /// later batch out gets a deadline of its own; none out, nothing is armed.
    private func ackDeadlinePassed(_ generation: Int) {
        state.withLock { state in
            state.counters.wakeups += 1
            guard state.generation == generation else { return }
            state.ackDeadlineArmed = false
            guard var out = state.outstanding else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= out.deadline {
                out.wait = min(out.wait * 2, Self.lastAckWait)
                out.deadline = now &+ Self.nanoseconds(out.wait)
                state.outstanding = out
                state.counters.resends += 1
                state.lastCall = now
                deliver(out.batchText)
            }
            armAckDeadline(&state)
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(max(0, seconds) * 1e9) }

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

    /// The driver could not reopen (it failed on bad bytes): a new one on the same handle. A batch
    /// it handed over that the page has not had is kept: the core gave those changes already.
    private func replace(_ id: ObjectIdentifier) {
        queue.async { [self] in
            state.withLock { state in
                state.counters.wakeups += 1
                guard let driver = state.driver, ObjectIdentifier(driver) == id, let client = state.client else { return }
                if let out = state.outstanding, out.driver === driver { state.outstanding?.driver = nil }
                if let held = state.held {
                    state.carried = held.bytes
                    state.held = nil
                }
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

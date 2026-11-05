public import Foundation
import CmuxNextCompat
import CmuxNextWakeups
import os

/// A chat's attachment that one client carries first and a better one takes over once it is up
/// (cmuxterm-hq#7086, lane c): a Cloud chat streams over the relay at once, and moves to the
/// machine's direct link when that link comes up, without the page seeing a close. If the direct
/// link never comes up, the chat stays on the relay.
///
/// Nothing is lost or repeated across a move:
/// - Records: the page gets each seq once, in order. The new client attaches from the newest seq
///   forwarded (`after_seq`; each attachment is a gap-free prefix) and pages to the end. Its records
///   are held until the cutover and then flushed past that seq; the old client keeps the page live
///   until then.
/// - Calls (prompts, cancel, permission answers, picks): each goes over one client. The cutover
///   waits until none is in flight on the old client, and a call made meanwhile waits and goes over
///   the new one.
///
/// A move that fails at any step keeps the old client. Once moved, the end of the new client's
/// attachment moves the chat back to the old one from the newest seq. Only an end the chat cannot
/// recover from (both clients gone, or the old one's end before any move) reaches the page as
/// `.closed`, and the page reconnects and replays as it does today.
public nonisolated final class AgentSessionCarrierSwitch: AgentSessionRemoteClient {
    /// How long a move waits for the calls in flight on the old client before it gives up.
    public static let drainLimit: Duration = .seconds(10)

    private struct State {
        var handler: (@Sendable (AgentSessionRemoteEvent) -> Void)?
        /// The page's own attach request (its `kinds` filter every later attach); nil before attach.
        var page: AgentSessionPage?
        /// The client calls go over now.
        var current: any AgentSessionRemoteClient
        /// The client that took over (nil until a move completed).
        var preferred: (any AgentSessionRemoteClient)?
        /// The attachment whose events reach the page now; any other's are dropped.
        var live: UInt64 = 0
        /// The attachment that was live before a refused re-attach: the client may still push to it
        /// (`AgentSessionAttachClient` keeps the earlier handler when it never sent the attach), so
        /// both reach the page until the next attach or cutover.
        var alsoLive: UInt64?
        var nextGeneration: UInt64 = 0
        /// The attachment being brought up, whose events wait in ``buffer`` for the cutover.
        var buffering: UInt64?
        var buffer: [AgentSessionRemoteEvent] = []
        /// The attachment being brought up ended before its cutover.
        var bufferEnded = false
        /// The newest record seq the page got (or its attach answer covered).
        var newest: UInt64 = 0
        /// Calls running on ``current``.
        var inFlight = 0
        /// New calls wait (a cutover or a fall-back is under way).
        var holding = false
        var held: [Waiter] = []
        var drained: [UUID: CheckedContinuation<Bool, Never>] = [:]
        var moving = false
        var ended = false
        /// Events for the page, delivered in order by one caller at a time (``deliver()``).
        var outbox: [AgentSessionRemoteEvent] = []
        var delivering = false
    }

    /// A call waiting for a cutover or a fall-back; resumed with the client it then goes over.
    private typealias Waiter = CheckedContinuation<any AgentSessionRemoteClient, Never>

    /// The calls a cutover, fall-back or end let go, each counted in flight on `client`.
    private struct Released: Sendable {
        let client: any AgentSessionRemoteClient
        let waiters: [Waiter]

        func resume() {
            for waiter in waiters { waiter.resume(returning: client) }
        }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.carrier")
    private let fallback: any AgentSessionRemoteClient
    private let state: Mutex<State>

    /// A chat carried by `fallback` (the relay) until ``move(to:drainLimit:)`` hands it over.
    public init(fallback: any AgentSessionRemoteClient) {
        self.fallback = fallback
        state = Mutex(State(current: fallback))
    }

    public var isReadOnly: Bool { state.withLock { $0.current }.isReadOnly }

    /// Whether the chat runs over the client that took over.
    public var moved: Bool { state.withLock { $0.preferred != nil } }

    /// New calls wait for a cutover or a fall-back now.
    var holding: Bool { state.withLock { $0.holding } }

    // MARK: The move

    /// Moves the chat to `preferred` (the direct link): true once it carries the chat. False, with
    /// the chat still on the old client and `preferred` closed, when it could not attach, ended
    /// before the cutover, or the calls in flight did not finish within `drainLimit`.
    public func move(to preferred: any AgentSessionRemoteClient, drainLimit: Duration = drainLimit) async -> Bool {
        let start = state.withLock { state -> (AgentSessionPage, UInt64, UInt64)? in
            guard !state.ended, !state.moving, state.preferred == nil, let page = state.page else { return nil }
            state.moving = true
            return (page, state.newest, Self.beginBuffering(&state))
        }
        guard let (page, from, generation) = start else { return false }
        do {
            try await attach(preferred, from: from, kinds: page.kinds, generation: generation)
        } catch {
            Self.logger.info("carrier move: attach failed: \(String(describing: error), privacy: .public)")
            return await abandon(preferred)
        }
        state.withLock { $0.holding = true }
        guard await drained(within: drainLimit) else {
            Self.logger.info("carrier move: calls in flight did not finish; staying")
            return await abandon(preferred)
        }
        guard cutover(to: preferred, generation: generation, preferred: true) else { return await abandon(preferred) }
        Self.logger.info("carrier move: moved")
        await fallback.detach()
        return true
    }

    /// Back to the old client after the one that took over ended: from the newest seq, with calls
    /// held meanwhile. The page sees `.closed` only when that attach fails too.
    private func fallBack(_ reason: String) async {
        let start = state.withLock { state -> (AgentSessionPage, UInt64, UInt64, (any AgentSessionRemoteClient)?)? in
            guard !state.ended, let page = state.page else { return nil }
            // No move starts while the chat is on its way back.
            state.moving = true
            defer { state.preferred = nil }
            return (page, state.newest, Self.beginBuffering(&state), state.preferred)
        }
        guard let (page, from, generation, gone) = start else { return }
        Self.logger.info("carrier: the direct attachment ended (\(reason, privacy: .public)); back to the relay")
        await gone?.close()
        do {
            try await attach(fallback, from: from, kinds: page.kinds, generation: generation)
            // Calls still running on the direct client end before held ones go to the relay, so a
            // newer prompt, cancel or answer never overtakes an older one. The direct client is
            // closed, so they end soon; past the limit the relay takes the chat anyway.
            if !(await drained(within: Self.drainLimit)) {
                Self.logger.info("carrier: direct calls still running after the drain limit; relay takes the chat")
            }
            if cutover(to: fallback, generation: generation, preferred: false) { return }
        } catch {
            Self.logger.info("carrier: relay re-attach failed: \(String(describing: error), privacy: .public)")
        }
        let released = state.withLock { state -> Released in
            state.ended = true
            state.moving = false
            state.buffering = nil
            state.buffer = []
            state.outbox.append(.closed(reason))
            return Self.release(&state)
        }
        deliver()
        released.resume()
    }

    private static func beginBuffering(_ state: inout State) -> UInt64 {
        state.nextGeneration += 1
        state.buffering = state.nextGeneration
        state.buffer = []
        state.bufferEnded = false
        return state.nextGeneration
    }

    /// Attaches `client` from `from` and pages to the end; its records join the buffer ahead of the
    /// pushes that arrived meanwhile.
    private func attach(_ client: any AgentSessionRemoteClient, from: UInt64, kinds: [String]?,
                        generation: UInt64) async throws {
        var page = Self.page(try await client.attach(AgentSessionPage(afterSeq: from, kinds: kinds), events: handler(for: generation)))
        var records = page.records
        var cursor = from
        // Each page moves the cursor forward, so this ends at the log's end.
        while page.hasMore, let last = page.newestSeq, last > cursor {
            cursor = last
            page = Self.page(try await client.events(AgentSessionPage(afterSeq: cursor, kinds: kinds)))
            records += page.records
        }
        let replay = records.map { AgentSessionRemoteEvent.record($0) }
        state.withLock { $0.buffer.insert(contentsOf: replay, at: 0) }
    }

    /// Makes `client` the chat's carrier: the buffer's records past the newest seq go to the page,
    /// then that attachment's own. False when it ended before this. `preferred` is a move (not a
    /// fall-back to the relay).
    private func cutover(to client: any AgentSessionRemoteClient, generation: UInt64, preferred: Bool) -> Bool {
        let released = state.withLock { state -> Released? in
            guard state.buffering == generation, !state.bufferEnded, !state.ended else { return nil }
            for event in state.buffer { Self.admit(event, into: &state) }
            state.buffer = []
            state.buffering = nil
            state.live = generation
            state.alsoLive = nil
            state.current = client
            if preferred { state.preferred = client }
            state.moving = false
            return Self.release(&state)
        }
        guard let released else { return false }
        deliver()
        released.resume()
        return true
    }

    /// A move that did not happen: the old client keeps the chat and `preferred` is closed.
    private func abandon(_ preferred: any AgentSessionRemoteClient) async -> Bool {
        let released = state.withLock { state -> Released in
            state.buffering = nil
            state.buffer = []
            state.moving = false
            return Self.release(&state)
        }
        released.resume()
        await preferred.close()
        return false
    }

    /// Lets the held calls go, each counted in flight on the chat's carrier.
    private static func release(_ state: inout State) -> Released {
        state.holding = false
        state.inFlight += state.held.count
        defer { state.held = [] }
        return Released(client: state.current, waiters: state.held)
    }

    // MARK: Events

    private func handler(for generation: UInt64) -> @Sendable (AgentSessionRemoteEvent) -> Void {
        { [weak self] event in self?.received(event, from: generation) }
    }

    private func received(_ event: AgentSessionRemoteEvent, from generation: UInt64) {
        enum Next { case none, deliver, fallBack(String) }
        let next = state.withLock { state -> Next in
            if state.buffering == generation {
                if case .closed = event { state.bufferEnded = true } else { state.buffer.append(event) }
                return .none
            }
            guard generation == state.live || generation == state.alsoLive, !state.ended else { return .none }
            if case .closed(let reason) = event {
                // The chat is on the client that took over: it goes back to the relay instead.
                if state.preferred != nil {
                    state.live = 0
                    state.alsoLive = nil
                    state.holding = true
                    return .fallBack(reason)
                }
                state.ended = true
            }
            Self.admit(event, into: &state)
            return .deliver
        }
        switch next {
        case .none: return
        case .deliver: deliver()
        case .fallBack(let reason):
            // task-owner: the fall-back owns the chat until it re-attached or ended the attachment
            Task { await self.fallBack(reason) }
        }
    }

    /// Queues `event` for the page; a record at or below the newest seq it got is dropped.
    private static func admit(_ event: AgentSessionRemoteEvent, into state: inout State) {
        if case .record(let data) = event, let seq = seq(of: data) {
            guard seq > state.newest else { return }
            state.newest = seq
        }
        state.outbox.append(event)
    }

    /// Hands the outbox to the page in order, one caller at a time.
    private func deliver() {
        // Ends once the outbox is empty, or another caller is delivering it.
        while let (handler, events) = nextBatch() {
            for event in events { handler(event) }
            state.withLock { $0.delivering = false }
        }
    }

    private func nextBatch() -> (@Sendable (AgentSessionRemoteEvent) -> Void, [AgentSessionRemoteEvent])? {
        state.withLock { state in
            guard !state.delivering, !state.outbox.isEmpty, let handler = state.handler else { return nil }
            state.delivering = true
            defer { state.outbox = [] }
            return (handler, state.outbox)
        }
    }

    // MARK: Calls

    /// Runs `work` on the chat's carrier; waits first while a cutover or fall-back is under way.
    private func call<Value: Sendable>(_ work: (any AgentSessionRemoteClient) async throws -> Value) async throws -> Value {
        let client = await admitCall()
        defer { finishCall() }
        return try await work(client)
    }

    private func admitCall() async -> any AgentSessionRemoteClient {
        await withCheckedContinuation { (waiter: Waiter) in
            let client = state.withLock { state -> (any AgentSessionRemoteClient)? in
                guard !state.holding else {
                    state.held.append(waiter)
                    return nil
                }
                state.inFlight += 1
                return state.current
            }
            if let client { waiter.resume(returning: client) }
        }
    }

    private func finishCall() {
        let waiters = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            state.inFlight -= 1
            guard state.inFlight == 0 else { return [] }
            defer { state.drained = [:] }
            return Array(state.drained.values)
        }
        for waiter in waiters { waiter.resume(returning: true) }
    }

    /// True once no call runs on the old client, false after `limit`.
    private func drained(within limit: Duration) async -> Bool {
        let id = UUID()
        let deadline = DemandTimer(owner: "agent-pane.carrier-move-drain")
        let drained = await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
            let now = state.withLock { state -> Bool in
                guard state.inFlight > 0 else { return true }
                state.drained[id] = waiter
                return false
            }
            if now {
                waiter.resume(returning: true)
                return
            }
            deadline.schedule(after: limit) { [weak self] in
                self?.state.withLock { $0.drained.removeValue(forKey: id) }?.resume(returning: false)
            }
        }
        deadline.cancel()
        return drained
    }

    // MARK: AgentSessionRemoteClient

    public func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
        // A watch's one-record transcript read: the wire answers it as a sessions list and the page
        // never gets its record, so it sets neither what a move re-attaches with nor how far it reads.
        let watch = page.listing
        let (client, generation, before) = state.withLock { state in
            let before = (handler: state.handler, page: state.page, live: state.live)
            state.handler = handler
            if !watch || state.page == nil { state.page = page }
            state.nextGeneration += 1
            state.live = state.nextGeneration
            state.alsoLive = nil
            return (state.current, state.live, before)
        }
        let answer: Data
        do {
            answer = try await client.attach(page, events: self.handler(for: generation))
        } catch {
            // A refused re-attach keeps the attachment the page had live, unless another took over.
            // Its pushes may come on either handler: `AgentSessionAttachClient` installs the new one
            // before it sends and keeps it when the daemon refuses, and keeps the old one when the
            // attach was cancelled before it was sent. Both stay live; the page's handler and page too.
            state.withLock { state in
                guard state.live == generation else { return }
                state.handler = before.handler
                state.page = before.page
                state.alsoLive = before.live
            }
            throw error
        }
        if !watch {
            let covered = Self.covered(answer, by: page)
            state.withLock { $0.newest = max($0.newest, covered) }
        }
        return answer
    }

    /// A forward page the page gets here covers its records too, so a move replays past them.
    public func events(_ page: AgentSessionPage) async throws -> Data {
        let answer = try await call { try await $0.events(page) }
        if page.afterSeq != nil, page.beforeSeq == nil {
            let covered = Self.covered(answer, by: page)
            state.withLock { $0.newest = max($0.newest, covered) }
        }
        return answer
    }
    public func prompt(id: String, text: String) async throws -> Data { try await call { try await $0.prompt(id: id, text: text) } }
    public func prompt(id: String, content: Data) async throws -> Data { try await call { try await $0.prompt(id: id, content: content) } }
    public func cancel() async throws { try await call { try await $0.cancel() } }

    public func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                           personDecision: String?) async throws {
        try await call {
            try await $0.permission(id: id, option: option, answers: answers, annotations: annotations,
                                    decisionNonce: decisionNonce, personDecision: personDecision)
        }
    }

    public func children() async throws -> Data { try await call { try await $0.children() } }
    public func media(path: String) async throws -> Data { try await call { try await $0.media(path: path) } }
    public func typing(_ on: Bool) async throws { try await call { try await $0.typing(on) } }
    public func view(_ visible: Bool) async throws { try await call { try await $0.view(visible) } }
    public func setModel(_ modelId: String) async throws -> Data { try await call { try await $0.setModel(modelId) } }
    public func setMode(_ modeId: String) async throws -> Data { try await call { try await $0.setMode(modeId) } }
    public func setConfig(id configId: String, value: String) async throws -> Data {
        try await call { try await $0.setConfig(id: configId, value: value) }
    }
    public func servesLogin() async -> Bool { (try? await call { await $0.servesLogin() }) ?? false }
    public func login(_ op: String, _ fields: [String: String]) async throws -> Data { try await call { try await $0.login(op, fields) } }

    public func detach() async {
        let clients = end()
        for client in clients { await client.detach() }
    }

    public func close() async {
        let clients = end()
        for client in clients { await client.close() }
    }

    private func end() -> [any AgentSessionRemoteClient] {
        let (clients, released) = state.withLock { state -> ([any AgentSessionRemoteClient], Released) in
            state.ended = true
            state.buffering = nil
            state.buffer = []
            let clients: [any AgentSessionRemoteClient] = [fallback] + (state.preferred.map { [$0] } ?? [])
            return (clients, Self.release(&state))
        }
        released.resume()
        return clients
    }

    // MARK: Pages

    /// A record's `seq` (acpmux's `eventStream` form), nil when it has none.
    static func seq(of record: Data) -> UInt64? {
        guard let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any] else { return nil }
        return (object["seq"] as? NSNumber)?.uint64Value
    }

    /// The newest seq through which `answer` (a page asked as `request`) holds every record: acpmux's
    /// `pageThrough`. Without it, by acpmux's own rule: the log's head (`lastSeq`) for the newest page
    /// or a forward one with nothing more to read, else the page's own newest record. `lastSeq` alone
    /// is the head even when the page stops short of it.
    static func covered(_ answer: Data, by request: AgentSessionPage) -> UInt64 {
        let object = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] ?? [:]
        if let through = (object["pageThrough"] as? NSNumber)?.uint64Value { return through }
        let page = page(answer)
        let toHead = request.beforeSeq == nil && (request.afterSeq == nil || !page.hasMore)
        return toHead ? page.lastSeq : page.newestSeq ?? 0
    }

    /// An attach or events answer: its records (each as JSON), whether more follow, the newest
    /// record seq and the log's head (`lastSeq`, at least the newest record).
    static func page(_ answer: Data) -> (records: [Data], hasMore: Bool, newestSeq: UInt64?, lastSeq: UInt64) {
        guard let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any] else { return ([], false, nil, 0) }
        let events = object["events"] as? [Any] ?? []
        let records = events.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        let newest = records.compactMap(seq(of:)).max()
        let lastSeq = (object["lastSeq"] as? NSNumber)?.uint64Value ?? newest ?? 0
        return (records, object["hasMore"] as? Bool ?? false, newest, max(lastSeq, newest ?? 0))
    }
}

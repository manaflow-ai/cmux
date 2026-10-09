public import CmuxMobileWire
import Foundation

/// The client side of one control-plane socket (b1-control-do.md): connects, negotiates
/// `hello`, keeps stream mirrors in order with revision cursors, reconnects with backoff and
/// resumes every stream from its last applied seq, resends undecided ops with their original
/// idempotency keys, answers reads by id, and carries WebRTC signals both ways.
///
/// Nothing queues while disconnected: `submit`, `read` and `sendSignal` throw `.notConnected`.
/// Everything is bounded (E1): `states` keeps the newest 16, a subscriber that falls
/// `streamBacklogLimit` updates behind is resynced from a fresh snapshot, and past
/// `outboxLimit` frames waiting for the socket sends fail with `.busy`.
public actor ControlPlaneClient {
    public nonisolated let states: AsyncStream<ControlPlaneState>
    /// Signals relayed to this client (`from` is the sender's authenticated install).
    public nonisolated let signals: AsyncStream<SignalFrame>

    private let configuration: ControlPlaneConfiguration
    private let transport: any ControlPlaneTransport
    private let tokenProvider: @Sendable () async throws -> String
    private let stateSink: AsyncStream<ControlPlaneState>.Continuation
    private let signalSink: AsyncStream<SignalFrame>.Continuation

    private var connection: (any ControlPlaneConnection)?
    /// Frames of the current connection, sent in order by one sender task.
    private var outbox: AsyncStream<String>.Continuation?
    private var negotiated: HelloOKFrame?
    private var subscriptions: [String: StreamSubscription] = [:]
    private var pendingOps: [String: PendingOp] = [:]
    private var pendingReads: [Int: CheckedContinuation<ReadResultFrame, any Error>] = [:]
    private var nextReadID = 1
    private var runner: Task<Void, Never>?
    private(set) public var state: ControlPlaneState = .idle

    public init(configuration: ControlPlaneConfiguration, transport: any ControlPlaneTransport,
                tokenProvider: @escaping @Sendable () async throws -> String) {
        self.configuration = configuration
        self.transport = transport
        self.tokenProvider = tokenProvider
        (states, stateSink) = AsyncStream.makeStream(of: ControlPlaneState.self, bufferingPolicy: .bufferingNewest(16))
        (signals, signalSink) = AsyncStream.makeStream(of: SignalFrame.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// The version and caps of the current session, if connected.
    public var session: HelloOKFrame? { negotiated }

    public func start() {
        guard runner == nil else { return }
        runner = Task { await self.run() }
    }

    /// Closes the socket and fails everything in flight. The client does not reconnect.
    public func stop() async {
        runner?.cancel()
        runner = nil
        if let connection { await connection.close(code: 1000) }
        outbox?.finish()
        outbox = nil
        connection = nil
        negotiated = nil
        failAll(.stopped)
        for (_, sub) in subscriptions { sub.buffer.finish() }
        subscriptions = [:]
        publish(.stopped)
        stateSink.finish()
        signalSink.finish()
    }

    // MARK: Streams

    /// Mirrors `stream`: a snapshot first (or the events after a known seq on resume), then
    /// contiguous events. A second call for the same stream replaces the first subscriber.
    public func subscribe(_ stream: String) -> AsyncStream<StreamUpdate> {
        let buffer = StreamUpdateBuffer(limit: configuration.streamBacklogLimit)
        subscriptions[stream]?.buffer.finish()
        subscriptions[stream] = StreamSubscription(seq: nil, buffer: buffer)
        if connection != nil, negotiated != nil { sendInternal(.subscribe(SubscribeFrame(stream: stream))) }
        return buffer.stream
    }

    public func unsubscribe(_ stream: String) {
        guard let sub = subscriptions.removeValue(forKey: stream) else { return }
        sub.buffer.finish()
        if negotiated != nil { sendInternal(.unsubscribe(UnsubscribeFrame(stream: stream))) }
    }

    /// The last applied seq of a stream (its revision cursor).
    public func cursor(of stream: String) -> UInt64? { subscriptions[stream]?.seq }

    // MARK: Requests

    /// Sends one op and waits for the owner's result or reject. After a reconnect the op is
    /// resent with the same key, so the owner dedupes it.
    public func submit(_ op: OpFrame) async throws -> OpOutcome {
        guard connection != nil, negotiated != nil else { throw ControlPlaneError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            if let old = pendingOps[op.idempotencyKey] { old.continuation.resume(throwing: ControlPlaneError.stopped) }
            pendingOps[op.idempotencyKey] = PendingOp(frame: op, continuation: continuation)
            if !trySend(.op(op)) {
                pendingOps.removeValue(forKey: op.idempotencyKey)?.continuation.resume(throwing: ControlPlaneError.busy)
            }
        }
    }

    public func read(_ op: String, params: JSONValue = .object([:]), stream: String? = nil) async throws -> ReadResultFrame {
        guard connection != nil, negotiated != nil else { throw ControlPlaneError.notConnected }
        let id = nextReadID
        nextReadID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingReads[id] = continuation
            if !trySend(.read(ReadFrame(id: id, op: op, params: params, stream: stream))) {
                pendingReads.removeValue(forKey: id)?.resume(throwing: ControlPlaneError.busy)
            }
        }
    }

    /// Sends a signal; the relay sets `from`, so any value here is dropped.
    public func sendSignal(_ signal: SignalFrame) throws {
        guard connection != nil, negotiated != nil else { throw ControlPlaneError.notConnected }
        var out = signal
        out.from = nil
        guard trySend(.signal(out)) else { throw ControlPlaneError.busy }
    }

    /// Sends every undecided op again with its key (for example when `host:` reports the Mac back
    /// online after an `owner.unreachable` whose outcome was unknown). The owner dedupes.
    public func resendPending() {
        guard negotiated != nil else { return }
        for key in pendingOps.keys.sorted() {
            pendingOps[key]?.resent = true
            if let op = pendingOps[key] { sendInternal(.op(op.frame)) }
        }
    }

    /// Whether this device is actively viewing (app foreground). Feeds host viewer counts.
    public func setPresence(active: Bool, client: String = "ios") throws {
        guard connection != nil, negotiated != nil else { throw ControlPlaneError.notConnected }
        guard trySend(.presenceSet(PresenceSetFrame(state: PresenceState(active: active, client: client)))) else {
            throw ControlPlaneError.busy
        }
    }

    // MARK: Session loop

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            publish(.connecting(attempt: attempt))
            do {
                let token = try await tokenProvider()
                let conn = try await transport.connect(url: configuration.url, protocols: configuration.protocols(token: token))
                // `stop()` may have run while connecting: never keep a socket nobody owns.
                if Task.isCancelled {
                    await conn.close(code: 1000)
                    return
                }
                connection = conn
                let (frames, sink) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(configuration.outboxLimit))
                outbox = sink
                let sender = Task {
                    for await text in frames { try? await conn.send(text) }
                }
                defer { sender.cancel() }
                sendInternal(.hello(HelloFrame(min: configuration.minVersion, max: configuration.maxVersion, caps: configuration.caps, client: configuration.client)))
                while !Task.isCancelled {
                    let text = try await conn.receive()
                    if try handle(text) { attempt = 0 }
                }
            } catch let error as ControlPlaneError {
                return terminate(error)
            } catch let close as ControlPlaneCloseError where close.isTerminal {
                return terminate(.closed(close))
            } catch {
                if Task.isCancelled { return }
            }
            disconnected()
            publish(.disconnected(attempt: attempt))
            do {
                try await configuration.reconnect.sleep(configuration.reconnect.delay(attempt: attempt))
            } catch {
                return
            }
            attempt += 1
        }
    }

    /// Handles one frame; returns true when it completed the handshake.
    private func handle(_ text: String) throws -> Bool {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            return false
        }
        if value["t"]?.stringValue == "error" { try handleError(value); return false }
        guard let frame = try? MobileFrame(value: value) else { return false }
        switch frame {
        case .helloOK(let ok):
            negotiated = ok
            publish(.connected(ok))
            resume()
            return true
        case .snapshot(let snapshot):
            guard var sub = subscriptions[snapshot.stream] else { return false }
            // A snapshot always restores: it may carry a new epoch at a lower seq.
            sub.seq = snapshot.seq
            sub.epoch = snapshot.epoch
            sub.repairing = false
            subscriptions[snapshot.stream] = sub
            // A snapshot supersedes whatever the subscriber has not read yet.
            if !sub.buffer.push(.snapshot(snapshot)) {
                sub.buffer.clear()
                _ = sub.buffer.push(.snapshot(snapshot))
            }
        case .event(let event):
            apply(event)
        case .result(let result):
            pendingOps.removeValue(forKey: result.idempotencyKey)?.continuation.resume(returning: .applied(result))
        case .reject(let reject):
            // A resent op refused because the owner is offline may still have been applied by the
            // first send: it stays undecided (resent on reconnect or `resendPending`).
            if reject.code == "owner.unreachable", reject.retryable, pendingOps[reject.idempotencyKey]?.resent == true { return false }
            pendingOps.removeValue(forKey: reject.idempotencyKey)?.continuation.resume(returning: .rejected(reject))
        case .readResult(let result):
            pendingReads.removeValue(forKey: result.id)?.resume(returning: result)
        case .signal(let signal):
            signalSink.yield(signal)
        default:
            break
        }
        return false
    }

    /// `error` frames: a read failure (by id), an op whose outcome is unknown (by key), or a
    /// protocol error. Some servers omit `retryable`; it defaults to false.
    private func handleError(_ value: JSONValue) throws {
        var object = value.objectValue ?? [:]
        if object["retryable"] == nil { object["retryable"] = .bool(false) }
        guard let error = try? JSONValue.object(object).decode(as: ErrorFrame.self) else { return }
        if error.code == "proto.version_unsupported" { throw ControlPlaneError.versionUnsupported(error) }
        if let id = error.id { pendingReads.removeValue(forKey: id)?.resume(throwing: ControlPlaneError.remote(error)) }
        if let key = object["idempotency_key"]?.stringValue {
            // Outcome unknown (the owner went away mid-request): keep the intent; it is resent with
            // the same key after a reconnect or `resendPending` (OWNERSHIP-PRINCIPLES "Offline").
            if error.code == "owner.unreachable", error.retryable {
                pendingOps[key]?.resent = true
                return
            }
            pendingOps.removeValue(forKey: key)?.continuation.resume(throwing: ControlPlaneError.remote(error))
        }
    }

    private func apply(_ event: EventFrame) {
        guard var sub = subscriptions[event.stream], let seq = sub.seq else { return }
        if sub.repairing { return }
        // Another epoch (the owner's stream restarted): its seqs say nothing about this mirror, so
        // the cursor is reset and a fresh snapshot requested instead of dropping it as stale.
        if let epoch = event.epoch, epoch != sub.epoch {
            sub.seq = nil
            sub.repairing = true
            subscriptions[event.stream] = sub
            sendInternal(.snapshotRequest(SnapshotRequestFrame(stream: event.stream, pending: pendingKeys())))
            return
        }
        if event.seq <= seq { return }
        guard event.seq == seq + 1 else {
            // A gap: never apply out of order; the owner answers with a snapshot.
            sub.repairing = true
            subscriptions[event.stream] = sub
            sendInternal(.snapshotRequest(SnapshotRequestFrame(stream: event.stream, pending: pendingKeys())))
            return
        }
        guard sub.buffer.push(.event(event)) else {
            // The subscriber fell `streamBacklogLimit` behind: drop its backlog
            // and repair from a fresh snapshot instead of queueing without bound.
            sub.buffer.clear()
            sub.repairing = true
            subscriptions[event.stream] = sub
            sendInternal(.snapshotRequest(SnapshotRequestFrame(stream: event.stream, pending: pendingKeys())))
            return
        }
        sub.seq = event.seq
        subscriptions[event.stream] = sub
    }

    /// After `hello.ok`: every stream resumes from its cursor, then undecided ops are resent.
    private func resume() {
        let pending = pendingKeys()
        for (stream, sub) in subscriptions.sorted(by: { $0.key < $1.key }) {
            // With intents in flight the owner sends a snapshot carrying their decided keys.
            let after = pending.isEmpty ? sub.seq : nil
            sendInternal(.subscribe(SubscribeFrame(stream: stream, afterSeq: after, pending: pending.isEmpty ? nil : pending, epoch: after == nil ? nil : sub.epoch)))
        }
        for key in pendingOps.keys.sorted() {
            pendingOps[key]?.resent = true
            if let op = pendingOps[key] { sendInternal(.op(op.frame)) }
        }
    }

    private func pendingKeys() -> [String] { pendingOps.keys.sorted() }

    private func disconnected() {
        outbox?.finish()
        outbox = nil
        connection = nil
        negotiated = nil
        for sub in subscriptions.keys { subscriptions[sub]?.repairing = false }
        // Reads are not replayed: their callers retry. Ops stay pending and are resent.
        let reads = pendingReads
        pendingReads = [:]
        for (_, continuation) in reads { continuation.resume(throwing: ControlPlaneError.notConnected) }
    }

    private func terminate(_ error: ControlPlaneError) {
        outbox?.finish()
        outbox = nil
        connection = nil
        negotiated = nil
        failAll(error)
        publish(.failed(error))
        runner = nil
    }

    private func failAll(_ error: ControlPlaneError) {
        let ops = pendingOps
        pendingOps = [:]
        for (_, op) in ops { op.continuation.resume(throwing: error) }
        let reads = pendingReads
        pendingReads = [:]
        for (_, continuation) in reads { continuation.resume(throwing: error) }
    }

    private func publish(_ next: ControlPlaneState) {
        state = next
        stateSink.yield(next)
    }

    /// Queues a frame for the socket; false when `outboxLimit` frames already wait.
    @discardableResult
    private func trySend(_ frame: MobileFrame) -> Bool {
        guard let outbox, let text = try? Self.text(frame) else { return true }
        if case .dropped = outbox.yield(text) { return false }
        return true
    }

    /// A protocol frame the session needs (hello, subscribe, repair, resend).
    /// If the socket stopped draining, it is closed: the reconnect resumes
    /// every stream and resends pending ops.
    private func sendInternal(_ frame: MobileFrame) {
        guard !trySend(frame), let connection else { return }
        Task { await connection.close(code: 1013) }
    }

    private static func text(_ frame: MobileFrame) throws -> String {
        String(decoding: try frame.encoded(), as: UTF8.self)
    }
}

// One admitted E2E session between a phone and a Mac, multiplexed over one
// pair of relay legs. Everything after the handshake rides sealed frames:
// stream open/data/eof/reset (+credit flow control), the admit confirmation,
// session keepalive pings, and the close notice.
//
// Leg blips are invisible here (the leg resumes below); this layer dies only
// when cryptographic continuity is actually gone: the peer process restarted
// (keepalive timeout — new processes cannot decrypt old sessions), the leg
// RESET (provable loss), or an explicit close.

import Foundation

enum DorSessionRole: Sendable {
    case initiator
    case responder
}

/// The one seam a session needs from its leg, factored out so the E2E mux is
/// integration-testable without sockets.
protocol DorLegSending: Sendable {
    func send(_ payload: Data, to destination: UInt32) async throws
}

extension DorLeg: DorLegSending {}

/// Sendable facade over one mux stream; the session actor owns all state.
struct DorStreamHandle: DorStream {
    let descriptor: DorLaneDescriptor
    let id: UInt32
    private let session: DorSecureSession

    init(descriptor: DorLaneDescriptor, id: UInt32, session: DorSecureSession) {
        self.descriptor = descriptor
        self.id = id
        self.session = session
    }

    func read() async throws -> Data? {
        try await session.readStream(id)
    }

    func write(_ data: Data) async throws {
        try await session.writeStream(id, data: data)
    }

    func closeWrite() async {
        await session.closeWriteStream(id)
    }

    func close() async {
        await session.resetStream(id)
    }
}

public actor DorSecureSession: DorSecureSessionProtocol {
    public nonisolated let peer: DorAdmittedPeer
    public nonisolated let sessionID: String
    public nonisolated let events: AsyncStream<DorSessionEvent>

    private let role: DorSessionRole
    private let leg: any DorLegSending
    /// Host: the phone's leg id. Phone: 0 (the relay routes to the Mac).
    private let destination: UInt32
    private let journal: DorJournal
    private var sealer: DorSealer
    private var opener: DorOpener
    private let eventsContinuation: AsyncStream<DorSessionEvent>.Continuation

    private var streams: [UInt32: DorStreamState] = [:]
    private var nextStreamID: UInt32
    private var ended = false
    private var admitted = false
    private var admitWaiters: [CheckedContinuation<Bool, Never>] = []

    private var lastInbound = ContinuousClock.now
    private var keepaliveTask: Task<Void, Never>?
    /// Owner notification (engine/acceptor), separate from the app-consumed
    /// `events` stream so both can observe the end without sharing it.
    private var onEnded: (@Sendable (String) -> Void)?
    private static let maxStreams = 64
    private static let maxDescriptorBytes = 4 * 1024
    private static let maxSessionCloseBytes = DorSafety.maxReasonBytes
    /// The initiator paces pings; the responder just answers and times out.
    private static let pingInterval: Duration = .seconds(15)
    private static let keepaliveTimeout: Duration = .seconds(60)

    init(
        role: DorSessionRole,
        peer: DorAdmittedPeer,
        sessionID: String,
        keys: DorSessionKeys,
        leg: any DorLegSending,
        destination: UInt32,
        journal: DorJournal
    ) {
        self.role = role
        self.peer = peer
        self.sessionID = sessionID
        self.leg = leg
        self.destination = destination
        self.journal = journal
        switch role {
        case .initiator:
            self.sealer = DorSealer(key: keys.initiatorToResponder)
            self.opener = DorOpener(key: keys.responderToInitiator)
            self.nextStreamID = 1
        case .responder:
            self.sealer = DorSealer(key: keys.responderToInitiator)
            self.opener = DorOpener(key: keys.initiatorToResponder)
            self.nextStreamID = 2
        }
        (events, eventsContinuation) = AsyncStream<DorSessionEvent>.makeStream(
            bufferingPolicy: .unbounded)
    }

    nonisolated func setOnEnded(_ callback: @escaping @Sendable (String) -> Void) {
        Task { await self.storeOnEnded(callback) }
    }

    private func storeOnEnded(_ callback: @escaping @Sendable (String) -> Void) {
        if ended {
            callback("already-ended")
        } else {
            onEnded = callback
        }
    }

    /// Launch the keepalive loop (called once by the owner after creation).
    func activate() {
        guard keepaliveTask == nil, !ended else { return }
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: DorSecureSession.pingInterval)
                guard let self, await self.keepaliveTick() else { return }
            }
        }
    }

    private func keepaliveTick() async -> Bool {
        guard !ended else { return false }
        if ContinuousClock.now - lastInbound > Self.keepaliveTimeout {
            await endSession(reason: "keepalive-timeout", notifyPeer: false)
            return false
        }
        if role == .initiator {
            try? await sendMux(DorMuxFrame(op: .ping, streamID: 0))
        }
        return true
    }

    // MARK: - Admission confirmation

    /// Responder: seal-confirm the hs2 session id, completing admission.
    func sendAdmit() async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["session": sessionID])
        try await sendMux(DorMuxFrame(op: .admit, streamID: 0, payload: payload))
    }

    /// Initiator: wait until the sealed admit frame arrives (proof the
    /// responder derived the same keys), or the deadline passes.
    func waitAdmitted(timeout: Duration) async -> Bool {
        if admitted { return true }
        if ended { return false }
        let waited = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                admitWaiters.append(continuation)
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            await self.resolveAdmitWaiters(ended: false)
        }
        let result = await waited.value
        timer.cancel()
        return result
    }

    private func resolveAdmitWaiters(ended: Bool) {
        let verdict = admitted && !ended
        for waiter in admitWaiters {
            waiter.resume(returning: verdict)
        }
        admitWaiters = []
    }

    // MARK: - Inbound (called by the single leg consumer)

    /// Decrypt and dispatch one sealed leg payload addressed to this session.
    func handleInbound(_ framed: Data) async {
        guard !ended else { return }
        let plaintext: Data
        do {
            plaintext = try opener.open(framed)
        } catch {
            // Undecryptable ciphertext = not our session (stale peer process
            // or replay); drop without state change.
            journal.record(
                component: "session", event: "undecryptable",
                attributes: ["session": sessionID])
            return
        }
        lastInbound = ContinuousClock.now
        guard let frame = DorMuxFrame.decode(plaintext) else {
            journal.record(
                component: "session", event: "malformed-mux",
                attributes: ["session": sessionID])
            return
        }
        switch frame.op {
        case .open:
            guard frame.streamID != 0,
                  isPeerOwnedStreamID(frame.streamID),
                  frame.payload.count <= Self.maxDescriptorBytes,
                  streams[frame.streamID] == nil,
                  streams.count < Self.maxStreams,
                  let descriptor = try? JSONDecoder().decode(
                    DorLaneDescriptor.self, from: frame.payload),
                  descriptor.isValid
            else {
                if frame.streamID != 0, isPeerOwnedStreamID(frame.streamID),
                   streams[frame.streamID] == nil, streams.count >= Self.maxStreams
                {
                    await endSession(reason: "stream-capacity", notifyPeer: true)
                }
                return
            }
            let state = DorStreamState(id: frame.streamID, descriptor: descriptor)
            streams[frame.streamID] = state
            eventsContinuation.yield(
                .inboundStream(DorStreamHandle(
                    descriptor: descriptor, id: frame.streamID, session: self)))
        case .data:
            guard frame.streamID != 0, frame.payload.count <= DorMuxLimits.chunkBytes else {
                await endSession(reason: "stream-buffer-overflow", notifyPeer: true)
                return
            }
            guard let state = streams[frame.streamID] else { return }
            if !state.enqueue(frame.payload) {
                await endSession(reason: "stream-buffer-overflow", notifyPeer: true)
            }
        case .eof:
            guard frame.streamID != 0 else { return }
            streams[frame.streamID]?.finishEOF()
        case .reset:
            guard frame.streamID != 0 else { return }
            if let state = streams.removeValue(forKey: frame.streamID) {
                state.fail(DorStreamError.reset)
            }
        case .credit:
            guard frame.streamID != 0,
                  let bytes = frame.creditBytes,
                  bytes > 0,
                  let state = streams[frame.streamID],
                  state.addSendWindow(bytes)
            else {
                await endSession(reason: "invalid-credit", notifyPeer: true)
                return
            }
        case .admit:
            guard frame.streamID == 0,
                  let object = try? JSONSerialization.jsonObject(with: frame.payload)
                    as? [String: Any],
                  object.keys.count == 1,
                  object["session"] as? String == sessionID
            else { return }
            admitted = true
            resolveAdmitWaiters(ended: false)
        case .ping:
            guard frame.streamID == 0, frame.payload.isEmpty else { return }
            try? await sendMux(DorMuxFrame(op: .pong, streamID: 0))
        case .pong:
            guard frame.streamID == 0, frame.payload.isEmpty else { return }
        case .sessionClose:
            guard frame.streamID == 0, frame.payload.count <= Self.maxSessionCloseBytes else {
                await endSession(reason: "peer-closed", notifyPeer: false)
                return
            }
            let reason = DorSafety.stableReason(
                String(data: frame.payload, encoding: .utf8), fallback: "peer-closed")
            await endSession(reason: reason, notifyPeer: false)
        }
    }

    /// The leg lost continuity (or was stopped): everything above it is dead.
    func legFailed(reason: String) async {
        await endSession(reason: reason, notifyPeer: false)
    }

    // MARK: - DorSecureSessionProtocol

    public func openStream(_ descriptor: DorLaneDescriptor) async throws -> any DorStream {
        guard !ended else { throw DorStreamError.sessionEnded }
        guard descriptor.isValid, streams.count < Self.maxStreams else {
            throw DorStreamError.streamLimit
        }
        guard nextStreamID <= UInt32.max - 2 else {
            await endSession(reason: "stream-capacity", notifyPeer: false)
            throw DorStreamError.streamLimit
        }
        let id = nextStreamID
        nextStreamID &+= 2
        let state = DorStreamState(id: id, descriptor: descriptor)
        streams[id] = state
        let payload = try JSONEncoder().encode(descriptor)
        try await sendMux(DorMuxFrame(op: .open, streamID: id, payload: payload))
        return DorStreamHandle(descriptor: descriptor, id: id, session: self)
    }

    public func close(reason: String) async {
        await endSession(
            reason: DorSafety.stableReason(reason, fallback: "user-close"),
            notifyPeer: true)
    }

    // MARK: - Stream operations (via DorStreamHandle)

    func readStream(_ id: UInt32) async throws -> Data? {
        guard let state = streams[id] else {
            if ended { throw DorStreamError.sessionEnded }
            throw DorStreamError.reset
        }
        let chunk = try await state.read()
        if let chunk {
            // Replenish the peer's send window as the app actually consumes.
            let credit = state.consumeForCredit(chunk.count)
            if credit > 0 {
                try? await sendMux(DorMuxFrame(
                    op: .credit, streamID: id,
                    payload: DorMuxFrame.creditPayload(credit)))
            }
        }
        return chunk
    }

    func writeStream(_ id: UInt32, data: Data) async throws {
        guard !ended else { throw DorStreamError.sessionEnded }
        guard let state = streams[id] else { throw DorStreamError.reset }
        var offset = 0
        while offset < data.count {
            let chunk = data.subdata(
                in: offset..<min(offset + DorMuxLimits.chunkBytes, data.count))
            offset += chunk.count
            // Await window (backpressure), then seal and ship.
            try await state.acquireSendWindow(chunk.count)
            guard !ended, streams[id] != nil else { throw DorStreamError.reset }
            try await sendMux(DorMuxFrame(op: .data, streamID: id, payload: chunk))
        }
    }

    func closeWriteStream(_ id: UInt32) async {
        guard !ended, streams[id] != nil else { return }
        try? await sendMux(DorMuxFrame(op: .eof, streamID: id))
    }

    func resetStream(_ id: UInt32) async {
        guard let state = streams.removeValue(forKey: id) else { return }
        state.fail(DorStreamError.reset)
        guard !ended else { return }
        try? await sendMux(DorMuxFrame(op: .reset, streamID: id))
    }

    // MARK: - Internals

    private func sendMux(_ frame: DorMuxFrame) async throws {
        guard !ended else { throw DorStreamError.sessionEnded }
        let encoded = frame.encoded()
        guard encoded.count <= DorWire.maxDataFrameBytes else {
            await endSession(reason: "stream-buffer-overflow", notifyPeer: false)
            throw DorStreamError.sessionEnded
        }
        let sealed: Data
        do {
            sealed = try sealer.seal(encoded)
        } catch {
            await endSession(reason: "seal-failed", notifyPeer: false)
            throw DorStreamError.sessionEnded
        }
        try await leg.send(sealed, to: destination)
    }

    private func endSession(reason: String, notifyPeer: Bool) async {
        guard !ended else { return }
        let safeReason = DorSafety.stableReason(reason, fallback: "peer-error")
        if notifyPeer {
            // Best effort; sealed with the still-valid keys.
            if let sealed = try? sealer.seal(
                DorMuxFrame(op: .sessionClose, streamID: 0, payload: Data(safeReason.utf8)).encoded())
            {
                try? await leg.send(sealed, to: destination)
            }
        }
        ended = true
        keepaliveTask?.cancel()
        keepaliveTask = nil
        for (_, state) in streams {
            state.fail(DorStreamError.sessionEnded)
        }
        streams = [:]
        resolveAdmitWaiters(ended: true)
        journal.record(
            component: "session", event: "ended",
            attributes: ["session": sessionID, "reason": safeReason])
        eventsContinuation.yield(.ended(reason: safeReason))
        eventsContinuation.finish()
        onEnded?(safeReason)
        onEnded = nil
    }

    private func isPeerOwnedStreamID(_ id: UInt32) -> Bool {
        // Stream zero is reserved for session control. The initiator owns odd
        // ids and the responder owns even ids.
        guard id != 0 else { return false }
        return role == .initiator ? id.isMultiple(of: 2) : !id.isMultiple(of: 2)
    }
}

public enum DorStreamError: Error, Sendable {
    case reset
    case sessionEnded
    case streamLimit
}

/// Per-stream state: inbound buffer with read waiters, credit windows both
/// directions. A class guarded by the session actor (all calls arrive
/// actor-isolated) except the waiter continuations it resumes.
private final class DorStreamState: @unchecked Sendable {
    let id: UInt32
    let descriptor: DorLaneDescriptor

    private let lock = NSLock()
    private var buffer: [Data] = []
    private var bufferedBytes = 0
    private var eof = false
    private var failure: (any Swift.Error)?
    private var readWaiters: [CheckedContinuation<Data?, any Swift.Error>] = []

    private var sendWindow = DorMuxLimits.initialWindow
    private var windowWaiters: [(bytes: Int, continuation: CheckedContinuation<Void, any Swift.Error>)] = []
    private var consumedSinceCredit = 0

    /// Receive-side cap: a peer ignoring flow control gets the session ended.
    private static let maxBuffered = DorMuxLimits.initialWindow + 4 * DorMuxLimits.chunkBytes

    init(id: UInt32, descriptor: DorLaneDescriptor) {
        self.id = id
        self.descriptor = descriptor
    }

    // MARK: inbound

    /// False when the peer overran the receive window (session-fatal).
    func enqueue(_ data: Data) -> Bool {
        let waiter: CheckedContinuation<Data?, any Error>?
        lock.lock()
        if failure != nil {
            lock.unlock()
            return true
        }
        if bufferedBytes + data.count > Self.maxBuffered {
            lock.unlock()
            return false
        }
        if readWaiters.isEmpty {
            buffer.append(data)
            bufferedBytes += data.count
            waiter = nil
        } else {
            waiter = readWaiters.removeFirst()
            consumedSinceCredit += data.count
        }
        lock.unlock()
        waiter?.resume(returning: data)
        return true
    }

    func finishEOF() {
        lock.lock()
        eof = true
        let waiters = buffer.isEmpty ? readWaiters : []
        if buffer.isEmpty { readWaiters = [] }
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    func fail(_ error: any Swift.Error) {
        lock.lock()
        if failure == nil { failure = error }
        let readers = readWaiters
        readWaiters = []
        let writers = windowWaiters
        windowWaiters = []
        lock.unlock()
        for waiter in readers {
            waiter.resume(throwing: error)
        }
        for waiter in writers {
            waiter.continuation.resume(throwing: error)
        }
    }

    func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            // Synchronous section: check state and either resolve now or park
            // the waiter, all under one lock hold (no missed-wakeup window).
            lock.lock()
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            if let first = buffer.first {
                buffer.removeFirst()
                bufferedBytes -= first.count
                lock.unlock()
                continuation.resume(returning: first)
                return
            }
            if eof {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            readWaiters.append(continuation)
            lock.unlock()
        }
    }

    /// Bytes to credit back to the peer, batched.
    func consumeForCredit(_ bytes: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        consumedSinceCredit += bytes
        guard consumedSinceCredit >= DorMuxLimits.creditBatch else { return 0 }
        let credit = consumedSinceCredit
        consumedSinceCredit = 0
        return credit
    }

    // MARK: outbound window

    @discardableResult
    func addSendWindow(_ bytes: Int) -> Bool {
        lock.lock()
        guard bytes > 0,
              sendWindow <= DorMuxLimits.initialWindow,
              bytes <= DorMuxLimits.initialWindow - sendWindow
        else {
            lock.unlock()
            return false
        }
        sendWindow += bytes
        var resumable: [(Int, CheckedContinuation<Void, any Error>)] = []
        while let next = windowWaiters.first, sendWindow >= next.bytes {
            windowWaiters.removeFirst()
            sendWindow -= next.bytes
            resumable.append((next.bytes, next.continuation))
        }
        lock.unlock()
        for (_, continuation) in resumable {
            continuation.resume()
        }
        return true
    }

    func acquireSendWindow(_ bytes: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
            lock.lock()
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            if windowWaiters.isEmpty, sendWindow >= bytes {
                sendWindow -= bytes
                lock.unlock()
                continuation.resume()
                return
            }
            windowWaiters.append((bytes, continuation))
            lock.unlock()
        }
    }
}

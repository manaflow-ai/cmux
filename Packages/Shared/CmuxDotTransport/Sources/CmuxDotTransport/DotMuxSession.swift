// One admitted E2E session: ChaChaPoly-sealed mux over a leg's payload
// stream. Every sealed box carries exactly one mux frame:
//
//   [u8 type][u32be streamID][payload]
//     1 admit    responder→initiator key confirmation; payload = sessionID
//     2 open     first frame of a stream; payload = lane descriptor JSON
//     3 data     payload = raw bytes (≤ dataChunkBytes)
//     4 fin      orderly end of the sender's direction
//     5 reset    abrupt stream teardown
//     6 goaway   session close; payload = reason
//
// Ordering: the per-direction nonce counter (DotOpener rejects any skew)
// rides the leg's per-destination seq order, so one serialized outbound pump
// per session keeps seal order == wire order. Stream IDs: initiator odd from
// 1, responder even from 2 (the phone's control stream is always 1).

import Foundation

enum DotMuxFrameType: UInt8 {
    case admit = 1
    case open = 2
    case data = 3
    case fin = 4
    case reset = 5
    case goaway = 6
}

enum DotMuxError: Error, Sendable {
    case sessionEnded(String)
    case streamClosed
    case malformedFrame
    case notAdmitted
}

enum DotMux {
    /// Mux data chunk cap: keeps the sealed leg frame far inside the relay's
    /// 1 MiB WebSocket message cap (dialect frames reach 8 MiB and are split
    /// here; the receiver's byte-stream consumers reassemble incrementally).
    static let dataChunkBytes = 128 * 1024
    static let headerBytes = 5

    static func encode(_ type: DotMuxFrameType, streamID: UInt32, payload: Data) -> Data {
        var frame = Data(capacity: headerBytes + payload.count)
        frame.append(type.rawValue)
        withUnsafeBytes(of: streamID.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    static func decode(_ data: Data) -> (type: DotMuxFrameType, streamID: UInt32, payload: Data)? {
        guard data.count >= headerBytes else { return nil }
        let bytes = [UInt8](data.prefix(headerBytes))
        guard let type = DotMuxFrameType(rawValue: bytes[0]) else { return nil }
        let streamID = bytes[1...4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (type, streamID, data.subdata(in: headerBytes ..< data.count))
    }
}

enum DotMuxRole: Sendable {
    case initiator
    case responder
}

final actor DotMuxSession: DotSecureSessionProtocol {
    public nonisolated let peer: DotAdmittedPeer
    public nonisolated let sessionID: String
    public nonisolated let events: AsyncStream<DotSessionEvent>

    private let role: DotMuxRole
    private let journal: DotJournal
    /// Sends one sealed leg payload to this session's peer leg.
    private let transmit: @Sendable (Data) async throws -> Void
    /// Fires exactly once when the session ends (engine/acceptor cleanup).
    private let onEnd: @Sendable (String) -> Void
    private let eventContinuation: AsyncStream<DotSessionEvent>.Continuation

    private var sealer: DotSealer
    private var opener: DotOpener

    private struct StreamState {
        let descriptor: DotLaneDescriptor
        var inbound: [Data] = []
        var inboundClosed = false
        var resetReason: String?
        var readWaiters: [CheckedContinuation<Data?, any Error>] = []
        var writeClosed = false
    }

    private var streams: [UInt32: StreamState] = [:]
    private var nextStreamID: UInt32
    private var ended = false
    private var endReason: String?

    // Initiator-side key confirmation.
    private var admitted: Bool
    private var admitWaiters: [CheckedContinuation<Void, any Error>] = []

    // Serialized outbound pump (seal order must equal wire order).
    private var outbound: [Data] = []
    private var outboundBytes = 0
    private var outboundWaiter: CheckedContinuation<Void, Never>?
    private var creditWaiters: [CheckedContinuation<Void, Never>] = []
    private var pumpTask: Task<Void, Never>?
    private static let outboundCreditBytes = 4 * 1024 * 1024

    init(
        role: DotMuxRole,
        keys: DotSessionKeys,
        peer: DotAdmittedPeer,
        sessionID: String,
        journal: DotJournal,
        transmit: @escaping @Sendable (Data) async throws -> Void,
        onEnd: @escaping @Sendable (String) -> Void
    ) {
        self.role = role
        self.peer = peer
        self.sessionID = sessionID
        self.journal = journal
        self.transmit = transmit
        self.onEnd = onEnd
        switch role {
        case .initiator:
            sealer = DotSealer(key: keys.initiatorToResponder)
            opener = DotOpener(key: keys.responderToInitiator)
            nextStreamID = 1
            admitted = false
        case .responder:
            sealer = DotSealer(key: keys.responderToInitiator)
            opener = DotOpener(key: keys.initiatorToResponder)
            nextStreamID = 2
            admitted = true
        }
        (events, eventContinuation) = AsyncStream<DotSessionEvent>.makeStream()
        if role == .responder {
            // Key confirmation: the first sealed frame proves the responder
            // derived the same keys and names the session it admitted. The
            // pump that flushes it starts in `begin()`.
            let admit = DotMux.encode(
                .admit, streamID: 0, payload: Data(sessionID.utf8))
            outbound = [admit]
            outboundBytes = admit.count
        }
    }

    /// Start the outbound pump. Owners call this once right after init (an
    /// actor initializer cannot touch its own isolated state machinery).
    func begin() {
        guard pumpTask == nil, !ended else { return }
        pumpTask = Task { await self.runPump() }
    }

    // MARK: - DotSecureSessionProtocol

    func openStream(_ descriptor: DotLaneDescriptor) async throws -> any DotStream {
        guard !ended else { throw DotMuxError.sessionEnded(endReason ?? "ended") }
        guard admitted else { throw DotMuxError.notAdmitted }
        let id = nextStreamID
        nextStreamID &+= 2
        streams[id] = StreamState(descriptor: descriptor)
        let payload = try JSONEncoder().encode(descriptor)
        enqueue(DotMux.encode(.open, streamID: id, payload: payload))
        return DotMuxStream(session: self, id: id, descriptor: descriptor)
    }

    func close(reason: String) async {
        guard !ended else { return }
        // Best effort goaway ahead of teardown; the pump flushes it unless
        // the leg is already gone.
        enqueue(DotMux.encode(.goaway, streamID: 0, payload: Data(reason.utf8)))
        end(reason: reason, notifyPeer: false)
    }

    // MARK: - Wiring (engine/acceptor side)

    /// Inbound sealed leg payload (kind byte included).
    func handleInboundSealed(_ framed: Data) {
        guard !ended else { return }
        let plaintext: Data
        do {
            plaintext = try opener.open(framed)
        } catch {
            // Counter skew or decrypt failure ⇒ the E2E channel is broken
            // (desync is unrecoverable by design; fresh sessions re-key).
            end(reason: "decrypt-failed", notifyPeer: false)
            return
        }
        guard let frame = DotMux.decode(plaintext) else {
            end(reason: "malformed-mux-frame", notifyPeer: false)
            return
        }
        switch frame.type {
        case .admit:
            guard role == .initiator,
                String(data: frame.payload, encoding: .utf8) == sessionID
            else {
                end(reason: "admit-mismatch", notifyPeer: false)
                return
            }
            admitted = true
            let waiters = admitWaiters
            admitWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        case .open:
            handleOpen(streamID: frame.streamID, payload: frame.payload)
        case .data:
            handleData(streamID: frame.streamID, payload: frame.payload)
        case .fin:
            handleFin(streamID: frame.streamID)
        case .reset:
            handleReset(streamID: frame.streamID)
        case .goaway:
            let reason = String(data: frame.payload, encoding: .utf8) ?? "goaway"
            end(reason: "peer: \(reason)", notifyPeer: false)
        }
    }

    /// Initiator: await the responder's sealed admit (key confirmation). The
    /// caller bounds this externally.
    func waitAdmitted() async throws {
        guard !admitted else { return }
        guard !ended else { throw DotMuxError.sessionEnded(endReason ?? "ended") }
        try await withCheckedThrowingContinuation { continuation in
            admitWaiters.append(continuation)
        }
    }

    /// Session death from below (leg reset, engine shutdown): no goaway can
    /// be delivered, so tear down locally and notify the owner.
    func fail(reason: String) {
        end(reason: reason, notifyPeer: false)
    }

    var isEnded: Bool {
        ended
    }

    var isAdmitted: Bool {
        admitted
    }

    // MARK: - Stream operations (called by DotMuxStream)

    func readStream(_ id: UInt32) async throws -> Data? {
        guard var state = streams[id] else {
            if ended { throw DotMuxError.sessionEnded(endReason ?? "ended") }
            throw DotMuxError.streamClosed
        }
        if !state.inbound.isEmpty {
            let chunk = state.inbound.removeFirst()
            streams[id] = state
            return chunk
        }
        if let resetReason = state.resetReason {
            throw DotMuxError.sessionEnded(resetReason)
        }
        if state.inboundClosed {
            return nil
        }
        if ended {
            throw DotMuxError.sessionEnded(endReason ?? "ended")
        }
        return try await withCheckedThrowingContinuation { continuation in
            guard var state = streams[id] else {
                continuation.resume(throwing: DotMuxError.streamClosed)
                return
            }
            state.readWaiters.append(continuation)
            streams[id] = state
        }
    }

    func writeStream(_ id: UInt32, data: Data) async throws {
        guard !ended else { throw DotMuxError.sessionEnded(endReason ?? "ended") }
        guard let state = streams[id], !state.writeClosed,
            state.resetReason == nil
        else {
            throw DotMuxError.streamClosed
        }
        // Credit gate: bound the un-transmitted queue during bulk writes.
        while !ended, outboundBytes > Self.outboundCreditBytes {
            await withCheckedContinuation { continuation in
                creditWaiters.append(continuation)
            }
        }
        guard !ended else { throw DotMuxError.sessionEnded(endReason ?? "ended") }
        guard let live = streams[id], !live.writeClosed, live.resetReason == nil
        else {
            throw DotMuxError.streamClosed
        }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(
                offset, offsetBy: DotMux.dataChunkBytes,
                limitedBy: data.endIndex
            ) ?? data.endIndex
            enqueue(DotMux.encode(
                .data, streamID: id, payload: data.subdata(in: offset ..< end)))
            offset = end
        }
    }

    func finStream(_ id: UInt32) {
        guard !ended, var state = streams[id], !state.writeClosed else { return }
        state.writeClosed = true
        streams[id] = state
        enqueue(DotMux.encode(.fin, streamID: id, payload: Data()))
        releaseStreamIfDone(id)
    }

    func resetStream(_ id: UInt32) {
        guard var state = streams[id] else { return }
        if !ended {
            enqueue(DotMux.encode(.reset, streamID: id, payload: Data()))
        }
        let waiters = state.readWaiters
        state.readWaiters = []
        state.resetReason = "reset"
        state.writeClosed = true
        streams[id] = state
        for waiter in waiters {
            waiter.resume(throwing: DotMuxError.streamClosed)
        }
        streams[id] = nil
    }

    // MARK: - Inbound stream handling

    private func handleOpen(streamID: UInt32, payload: Data) {
        // Peer-opened IDs have the opposite parity of ours.
        let peerParity: UInt32 = role == .initiator ? 0 : 1
        guard streamID % 2 == peerParity, streams[streamID] == nil,
            let descriptor = try? JSONDecoder().decode(
                DotLaneDescriptor.self, from: payload)
        else {
            end(reason: "protocol-violation: open", notifyPeer: false)
            return
        }
        streams[streamID] = StreamState(descriptor: descriptor)
        eventContinuation.yield(.inboundStream(
            DotMuxStream(session: self, id: streamID, descriptor: descriptor)))
    }

    private func handleData(streamID: UInt32, payload: Data) {
        guard var state = streams[streamID], state.resetReason == nil else {
            // Locally closed already; the peer's in-flight frames drain here.
            return
        }
        if let waiter = state.readWaiters.first {
            state.readWaiters.removeFirst()
            streams[streamID] = state
            waiter.resume(returning: payload)
        } else {
            state.inbound.append(payload)
            streams[streamID] = state
        }
    }

    private func handleFin(streamID: UInt32) {
        guard var state = streams[streamID] else { return }
        state.inboundClosed = true
        if state.inbound.isEmpty {
            let waiters = state.readWaiters
            state.readWaiters = []
            streams[streamID] = state
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        } else {
            streams[streamID] = state
        }
        releaseStreamIfDone(streamID)
    }

    private func handleReset(streamID: UInt32) {
        guard var state = streams[streamID] else { return }
        let waiters = state.readWaiters
        state.readWaiters = []
        state.resetReason = "peer-reset"
        streams[streamID] = state
        for waiter in waiters {
            waiter.resume(throwing: DotMuxError.streamClosed)
        }
    }

    /// Fully closed both ways with nothing buffered ⇒ forget the stream so a
    /// long-lived session does not accumulate dead stream state.
    private func releaseStreamIfDone(_ id: UInt32) {
        guard let state = streams[id], state.writeClosed, state.inboundClosed,
            state.inbound.isEmpty, state.readWaiters.isEmpty
        else { return }
        streams[id] = nil
    }

    // MARK: - Outbound pump

    private func enqueue(_ plaintext: Data) {
        guard !ended else { return }
        outbound.append(plaintext)
        outboundBytes += plaintext.count
        if let outboundWaiter {
            self.outboundWaiter = nil
            outboundWaiter.resume()
        }
        if pumpTask == nil {
            pumpTask = Task { await self.runPump() }
        }
    }

    private func runPump() async {
        while !ended {
            if outbound.isEmpty {
                await withCheckedContinuation { continuation in
                    if ended || !outbound.isEmpty {
                        continuation.resume()
                    } else {
                        outboundWaiter = continuation
                    }
                }
                continue
            }
            let plaintext = outbound.removeFirst()
            outboundBytes -= plaintext.count
            if outboundBytes <= Self.outboundCreditBytes {
                let waiters = creditWaiters
                creditWaiters = []
                for waiter in waiters {
                    waiter.resume()
                }
            }
            let sealed: Data
            do {
                sealed = try sealer.seal(plaintext)
            } catch {
                end(reason: "seal-failed", notifyPeer: false)
                return
            }
            do {
                try await transmit(sealed)
            } catch {
                // The leg only throws when stopped or after a continuity
                // reset — either way this session is unrecoverable.
                end(reason: "leg-unavailable", notifyPeer: false)
                return
            }
        }
    }

    // MARK: - Teardown

    private func end(reason: String, notifyPeer: Bool) {
        guard !ended else { return }
        ended = true
        endReason = reason
        journal.record(
            component: "session", event: "ended",
            attributes: ["session": sessionID, "reason": reason]
        )
        for (id, state) in streams {
            var state = state
            let waiters = state.readWaiters
            state.readWaiters = []
            streams[id] = state
            for waiter in waiters {
                waiter.resume(throwing: DotMuxError.sessionEnded(reason))
            }
        }
        streams = [:]
        let admitWaiters = admitWaiters
        self.admitWaiters = []
        for waiter in admitWaiters {
            waiter.resume(throwing: DotMuxError.sessionEnded(reason))
        }
        let creditWaiters = creditWaiters
        self.creditWaiters = []
        for waiter in creditWaiters {
            waiter.resume()
        }
        if let outboundWaiter {
            self.outboundWaiter = nil
            outboundWaiter.resume()
        }
        eventContinuation.yield(.ended(reason: reason))
        eventContinuation.finish()
        onEnd(reason)
    }
}

/// The caller-facing stream handle. All state lives in the session actor.
final class DotMuxStream: DotStream, Sendable {
    let descriptor: DotLaneDescriptor
    private let session: DotMuxSession
    private let id: UInt32

    init(session: DotMuxSession, id: UInt32, descriptor: DotLaneDescriptor) {
        self.session = session
        self.id = id
        self.descriptor = descriptor
    }

    func read() async throws -> Data? {
        try await session.readStream(id)
    }

    func write(_ data: Data) async throws {
        try await session.writeStream(id, data: data)
    }

    func closeWrite() async {
        await session.finStream(id)
    }

    func close() async {
        await session.resetStream(id)
    }
}

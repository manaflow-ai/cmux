import Foundation

public enum TransportError: Error, Equatable {
    case pipeClosed
    case connectionClosedBeforeReply
    case unexpectedFrame(String)
    /// A dial exceeded its deadline (contract 4.6: bounded, never silent).
    /// UDP blackholes (firewalls, un-granted Local Network permission,
    /// offline tailnets) produce no errors, only silence; the deadline turns
    /// silence into a retryable failure.
    case dialTimeout
}

/// A bounded, ordered, async frame pipe: the in-memory stand-in for one QUIC
/// stream. Bounded so slow-reader backpressure is REAL in conformance tests
/// (contract 5.3): a full pipe suspends the sender, it never drops and never
/// kills anything.
public actor FramePipe {
    private var buffer: [Frame] = []
    private let capacity: Int
    private var closed = false
    private var sendWaiters: [(id: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var recvWaiters: [(id: Int, continuation: CheckedContinuation<Frame?, Never>)] = []
    private var waiterCounter = 0
    public private(set) var backpressureStalls = 0

    public init(capacity: Int = 64) {
        self.capacity = capacity
    }

    /// Suspends on backpressure. Observes task cancellation while parked:
    /// a cancelled sender throws CancellationError instead of leaking a
    /// continuation (the P1 runtime cancels tasks on supersession, mode
    /// switch, and teardown).
    public func send(_ frame: Frame) async throws {
        while buffer.count >= capacity && !closed {
            backpressureStalls += 1
            waiterCounter += 1
            let id = waiterCounter
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled || closed {
                        continuation.resume()
                    } else {
                        sendWaiters.append((id, continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelSendWaiter(id: id) }
            }
            try Task.checkCancellation()
        }
        guard !closed else { throw TransportError.pipeClosed }
        if !recvWaiters.isEmpty {
            recvWaiters.removeFirst().continuation.resume(returning: frame)
        } else {
            buffer.append(frame)
        }
    }

    /// Returns nil only after close AND a drained buffer, which is what makes
    /// a denial readable before the connection closes (contract 3.3). Also
    /// returns nil when the awaiting task is cancelled, so `for await` loops
    /// over `frames` end cleanly instead of parking forever.
    public func receive() async -> Frame? {
        if !buffer.isEmpty {
            let frame = buffer.removeFirst()
            if !sendWaiters.isEmpty {
                sendWaiters.removeFirst().continuation.resume()
            }
            return frame
        }
        if closed { return nil }
        waiterCounter += 1
        let id = waiterCounter
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || closed {
                    continuation.resume(returning: nil)
                } else if !buffer.isEmpty {
                    continuation.resume(returning: buffer.removeFirst())
                } else {
                    recvWaiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelRecvWaiter(id: id) }
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        for waiter in recvWaiters { waiter.continuation.resume(returning: nil) }
        recvWaiters.removeAll()
        for waiter in sendWaiters { waiter.continuation.resume() }
        sendWaiters.removeAll()
    }

    private func cancelSendWaiter(id: Int) {
        guard let index = sendWaiters.firstIndex(where: { $0.id == id }) else { return }
        sendWaiters.remove(at: index).continuation.resume()
    }

    private func cancelRecvWaiter(id: Int) {
        guard let index = recvWaiters.firstIndex(where: { $0.id == id }) else { return }
        recvWaiters.remove(at: index).continuation.resume(returning: nil)
    }
}

/// One endpoint's handle on a lane: ordered, lossless, independent (5.1).
public struct LaneEnd: TransportLane {
    public let name: String
    let outbound: FramePipe
    let inbound: FramePipe

    public func send(_ frame: Frame) async throws {
        try await outbound.send(frame)
    }

    public func receive() async -> Frame? {
        await inbound.receive()
    }

    public func closeOutbound() async {
        await outbound.close()
    }

    public var backpressureStalls: Int {
        get async { await outbound.backpressureStalls }
    }
}

/// The in-memory connection: a set of named lanes between side A (client) and
/// side B (host). Mirrors the real substrate's shape (one QUIC stream per
/// lane), so nothing above this layer changes when iroh replaces it in P1.
public actor LoopbackWire {
    public enum Side: Sendable {
        case a, b
    }

    private struct LanePipes {
        let aToB: FramePipe
        let bToA: FramePipe
    }

    private var lanes: [String: LanePipes] = [:]
    private let laneCapacity: Int
    public private(set) var isClosed = false
    /// Why the wire died, visible to both ends (the loopback analogue of a
    /// QUIC close reason; contract 3.3).
    public private(set) var termination: ConnectionTermination?

    public init(laneCapacity: Int = 64) {
        self.laneCapacity = laneCapacity
    }

    /// Lanes are created on first use by either side; both sides get matching
    /// ends. (Real accept-stream semantics arrive with the iroh substrate.)
    public func lane(_ name: String, for side: Side) -> LaneEnd {
        let pipes: LanePipes
        if let existing = lanes[name] {
            pipes = existing
        } else {
            pipes = LanePipes(
                aToB: FramePipe(capacity: laneCapacity),
                bToA: FramePipe(capacity: laneCapacity))
            lanes[name] = pipes
        }
        switch side {
        case .a: return LaneEnd(name: name, outbound: pipes.aToB, inbound: pipes.bToA)
        case .b: return LaneEnd(name: name, outbound: pipes.bToA, inbound: pipes.aToB)
        }
    }

    /// Simulates the whole connection dying (app kill, network gone). In-flight
    /// lane bytes die with the session, by contract (5.4).
    public func closeAll(reason: ConnectionTermination? = nil) async {
        if termination == nil { termination = reason }
        isClosed = true
        for pipes in lanes.values {
            await pipes.aToB.close()
            await pipes.bToA.close()
        }
    }
}

/// One side's face on a LoopbackWire, conforming to the substrate seam. The
/// optional authenticated key models what a real substrate's encryption layer
/// would have proven about the remote peer (contract 3.5).
public final class LoopbackConnectionEnd: PeerConnection {
    private let wire: LoopbackWire
    private let side: LoopbackWire.Side
    private let authenticatedKey: Data?

    public init(
        wire: LoopbackWire, side: LoopbackWire.Side, authenticatedRemoteKey: Data? = nil
    ) {
        self.wire = wire
        self.side = side
        self.authenticatedKey = authenticatedRemoteKey
    }

    public var authenticatedRemoteKey: Data? { authenticatedKey }

    public func lane(_ name: String) async -> any TransportLane {
        await wire.lane(name, for: side)
    }

    public func closeAll(reason: ConnectionTermination?) async {
        await wire.closeAll(reason: reason)
    }

    public func termination() async -> ConnectionTermination? {
        await wire.termination
    }

    public var isClosed: Bool {
        get async { await wire.isClosed }
    }
}

extension LoopbackWire {
    /// Both faces of this wire. `authenticatedClientKey` is what the host's
    /// substrate "authenticated" the client as; plain loopback has none.
    public nonisolated func makeEnds(authenticatedClientKey: Data? = nil)
        -> (client: LoopbackConnectionEnd, host: LoopbackConnectionEnd)
    {
        (
            LoopbackConnectionEnd(wire: self, side: .a),
            LoopbackConnectionEnd(
                wire: self, side: .b, authenticatedRemoteKey: authenticatedClientKey)
        )
    }
}

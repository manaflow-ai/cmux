import Foundation

/// Transport failures distinct from typed admission denials.
public enum TransportError: Error, Equatable {
    /// A send was attempted on a closed pipe or lane.
    case pipeClosed
    /// Admission ended without a reply or recognized denial close code.
    case connectionClosedBeforeReply
    /// The peer sent an unexpected frame type or malformed admission envelope.
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
    private var buffer = FIFOQueue<Frame>()
    private let capacity: Int
    private var closed = false
    private var sendWaiters = FIFOQueue<(id: Int, continuation: CheckedContinuation<Void, Never>)>()
    private var recvWaiters = FIFOQueue<(id: Int, continuation: CheckedContinuation<Frame?, Never>)>()
    private var waiterCounter = 0
    /// Number of times a sender waited because the bounded buffer was full.
    public private(set) var backpressureStalls = 0

    /// Number of receive continuations currently parked on this pipe.
    /// Internal so the test target reads it through `@testable import`.
    var waitingReceiverCount: Int { recvWaiters.count }

    /// Creates a bounded pipe whose senders suspend instead of dropping frames.
    /// - Parameter capacity: Positive frame capacity; defaults to 64.
    public init(capacity: Int = 64) {
        precondition(capacity > 0, "FramePipe capacity must be positive")
        self.capacity = capacity
    }

    /// Suspends on backpressure. Observes task cancellation while parked:
    /// a cancelled sender throws CancellationError instead of leaking a
    /// continuation (the P1 runtime cancels tasks on supersession, mode
    /// switch, and teardown).
    /// - Parameter frame: Next frame to enqueue in send order.
    /// - Throws: Cancellation while parked or ``TransportError/pipeClosed`` after close.
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
                        sendWaiters.append((id: id, continuation: continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancelSendWaiter(id: id) }
            }
            try Task.checkCancellation()
        }
        guard !closed else { throw TransportError.pipeClosed }
        if let waiter = recvWaiters.popFirst() {
            waiter.continuation.resume(returning: frame)
        } else {
            buffer.append(frame)
        }
    }

    /// Returns nil only after close AND a drained buffer, which is what makes
    /// a denial readable before the connection closes (contract 3.3). Also
    /// returns nil when the awaiting task is cancelled, so `for await` loops
    /// over `frames` end cleanly instead of parking forever.
    /// - Returns: A queued frame, or nil after close and drain or a cancelled wait.
    public func receive() async -> Frame? {
        if !buffer.isEmpty {
            let frame = buffer.popFirst()!
            if let waiter = sendWaiters.popFirst() {
                waiter.continuation.resume()
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
                    guard let frame = buffer.popFirst() else {
                        continuation.resume(returning: nil)
                        return
                    }
                    if let waiter = sendWaiters.popFirst() {
                        waiter.continuation.resume()
                    }
                    continuation.resume(returning: frame)
                } else {
                    recvWaiters.append((id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelRecvWaiter(id: id) }
        }
    }

    /// Idempotently rejects new sends and wakes waiters while preserving queued receive frames.
    public func close() {
        guard !closed else { return }
        closed = true
        while let waiter = recvWaiters.popFirst() {
            waiter.continuation.resume(returning: nil)
        }
        while let waiter = sendWaiters.popFirst() {
            waiter.continuation.resume()
        }
    }

    private func cancelSendWaiter(id: Int) {
        guard let waiter = sendWaiters.remove(where: { $0.id == id }) else { return }
        waiter.continuation.resume()
    }

    private func cancelRecvWaiter(id: Int) {
        guard let waiter = recvWaiters.remove(where: { $0.id == id }) else { return }
        waiter.continuation.resume(returning: nil)
    }
}

/// One endpoint's handle on a lane: ordered, lossless, independent (5.1).
public struct LaneEnd: TransportLane {
    /// Logical name shared by both ends of this lane.
    public let name: String
    let outbound: FramePipe
    let inbound: FramePipe
    private let closed: Bool

    init(name: String, outbound: FramePipe, inbound: FramePipe, closed: Bool = false) {
        self.name = name
        self.outbound = outbound
        self.inbound = inbound
        self.closed = closed
    }

    static func closed(name: String) -> LaneEnd {
        LaneEnd(name: name, outbound: FramePipe(), inbound: FramePipe(), closed: true)
    }

    /// Sends on this end's outbound pipe with bounded backpressure.
    /// - Parameter frame: Next frame to send.
    /// - Throws: Cancellation while parked or a closed-pipe error.
    public func send(_ frame: Frame) async throws {
        guard !closed else { throw TransportError.pipeClosed }
        try await outbound.send(frame)
    }

    /// Consumes the next inbound frame using the pipe's close and cancellation semantics.
    /// - Returns: The next frame, or nil when this receive direction ends.
    public func receive() async -> Frame? {
        guard !closed else { return nil }
        return await inbound.receive()
    }

    /// Half-closes outbound sending while leaving this end's receive pipe intact.
    public func closeOutbound() async {
        guard !closed else { return }
        await outbound.close()
    }

    /// Number of full-buffer waits on this end's outbound pipe.
    public var backpressureStalls: Int {
        get async {
            guard !closed else { return 0 }
            return await outbound.backpressureStalls
        }
    }
}

/// The in-memory connection: a set of named lanes between side A (client) and
/// side B (host). Mirrors the real substrate's shape (one QUIC stream per
/// lane), so nothing above this layer changes when iroh replaces it in P1.
public actor LoopbackWire {
    /// Selects one direction of the shared in-memory connection.
    public enum Side: Sendable {
        /// Client-facing end returned by ``makeEnds(authenticatedClientKey:)``.
        case a
        /// Host-facing end returned by ``makeEnds(authenticatedClientKey:)``.
        case b
    }

    private struct LanePipes {
        let aToB: FramePipe
        let bToA: FramePipe
    }

    private var lanes: [String: LanePipes] = [:]
    private let laneCapacity: Int
    /// Whether whole-wire closure has begun; new lane creation is then prohibited.
    public private(set) var isClosed = false
    /// Why the wire died, visible to both ends (the loopback analogue of a
    /// QUIC close reason; contract 3.3).
    public private(set) var termination: ConnectionTermination?

    /// Creates a wire with independent bounded pipes for each direction of each lane.
    /// - Parameter laneCapacity: Positive frame capacity per pipe; defaults to 64.
    public init(laneCapacity: Int = 64) {
        precondition(laneCapacity > 0, "Loopback lane capacity must be positive")
        self.laneCapacity = laneCapacity
    }

    /// Lanes are created on first use by either side; both sides get matching
    /// ends. (Real accept-stream semantics arrive with the iroh substrate.)
    /// - Parameters:
    ///   - name: Logical lane identifier shared by both peers.
    ///   - side: Direction from which the caller accesses the wire.
    /// - Returns: Matching lane end, or an ended lane if no lane exists after closure.
    public func lane(_ name: String, for side: Side) -> LaneEnd {
        let pipes: LanePipes
        if let existing = lanes[name] {
            pipes = existing
        } else if isClosed {
            return .closed(name: name)
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
    /// - Parameter reason: Attributed termination visible to both ends; defaults to none.
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

    /// Adapts one wire end to the same seam used by real QUIC connections.
    /// - Parameters:
    ///   - wire: Shared wire carrying both peers' traffic.
    ///   - side: This peer's direction on the wire.
    ///   - authenticatedRemoteKey: Simulated substrate proof; nil models unauthenticated loopback.
    public init(
        wire: LoopbackWire, side: LoopbackWire.Side, authenticatedRemoteKey: Data? = nil
    ) {
        self.wire = wire
        self.side = side
        self.authenticatedKey = authenticatedRemoteKey
    }

    /// Injected remote-key proof, not a key learned from an untrusted hello.
    public var authenticatedRemoteKey: Data? { authenticatedKey }

    /// Obtains this end's independently buffered named lane.
    /// - Parameter name: Logical lane identifier shared with the peer.
    /// - Returns: The corresponding lane end from the wire.
    public func lane(_ name: String) async -> any TransportLane {
        await wire.lane(name, for: side)
    }

    /// Closes the shared wire and wakes both peers' lane waiters.
    /// - Parameter reason: Optional attributed termination recorded on the wire.
    public func closeAll(reason: ConnectionTermination?) async {
        await wire.closeAll(reason: reason)
    }

    /// Reads the cause recorded on the shared wire; this does not wait for a future close.
    /// - Returns: Current wire termination, or nil if no reason has been recorded.
    public func termination() async -> ConnectionTermination? {
        await wire.termination
    }

    /// Whether the shared wire has begun whole-connection closure.
    public var isClosed: Bool {
        get async { await wire.isClosed }
    }
}

extension LoopbackWire {
    /// Both faces of this wire. `authenticatedClientKey` is what the host's
    /// substrate "authenticated" the client as; plain loopback has none.
    /// - Parameter authenticatedClientKey: Simulated client-key proof presented to the host.
    /// - Returns: Client and host adapters sharing this wire's lifecycle.
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

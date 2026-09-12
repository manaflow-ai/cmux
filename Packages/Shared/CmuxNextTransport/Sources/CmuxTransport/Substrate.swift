import Foundation

/// The substrate seam: everything above (admission, sessions, lanes, expiry
/// lifecycle) is written against these two protocols, so the loopback (P0),
/// the iroh substrate (iroh mode, P1), and the tailnet substrate (Tailscale
/// mode) slot in without touching a line of protocol logic. The hard mode
/// switch (contract 2.3) picks which substrate exists; nothing above it knows.

/// One ordered, lossless frame stream (contract 5.1). One QUIC stream in the
/// real substrates. A slow lane suspends its own sender only (5.3).
public protocol TransportLane: Sendable {
    /// Logical lane name, stable for the stream's lifetime.
    var name: String { get }
    /// Sends one frame in order, suspending under lane-local backpressure.
    /// - Parameter frame: Envelope to transmit.
    /// - Throws: An encoding or stream-send error.
    func send(_ frame: Frame) async throws
    /// Waits for one frame; only one receive loop may consume each lane end.
    /// - Returns: A frame, or nil on terminal stream end or cancellation.
    func receive() async -> Frame?
    /// How many times a send suspended on backpressure (contract 8.2).
    var backpressureStalls: Int { get async }
}

/// `for await frame in lane.frames`: AsyncSequence sugar over receive() with
/// identical pull semantics (no extra buffering), ending on lane close or on
/// task cancellation. Lanes are SINGLE-CONSUMER: run exactly one read loop
/// per lane end; two concurrent loops would split the frames between them.
public struct LaneFrames: AsyncSequence, Sendable {
    /// Each sequence element is one complete decoded frame.
    public typealias Element = Frame
    let lane: any TransportLane

    /// Pull-based iterator with no extra buffering or independent receive task.
    public struct AsyncIterator: AsyncIteratorProtocol {
        let lane: any TransportLane

        /// Waits for the next frame using the underlying lane's receive semantics.
        /// - Returns: A decoded frame, or nil when the lane ends.
        public mutating func next() async -> Frame? {
            await lane.receive()
        }
    }

    /// Creates an iterator; callers must not concurrently consume another iterator.
    /// - Returns: A direct pull adapter for the same lane.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(lane: lane)
    }
}

extension TransportLane {
    /// Single-consumer asynchronous frame sequence with no additional buffering.
    public var frames: LaneFrames { LaneFrames(lane: self) }
}

/// Why a connection ended, carried by the SUBSTRATE's own close mechanism
/// (QUIC CONNECTION_CLOSE code + reason bytes on iroh; stored on the wire in
/// loopback), so denials and attributed closes arrive without any timing
/// dependence (contract 3.3, 4.4). The code namespace is shared with
/// DenialCode.rawValue and CloseReason.code.
public struct ConnectionTermination: Sendable, Equatable {
    /// How confidently the substrate identified the close cause. A rendered
    /// FFI diagnostic can only provide an ambiguity hint when its format is
    /// unknown; callers must fail closed for that case.
    public enum Authority: Sendable, Equatable {
        /// The substrate provided a recognized, structured close cause.
        case authoritative
        /// The substrate supplied only an unrecognized diagnostic hint.
        case ambiguous
    }

    /// Stable denial or close code; not a free-form peer diagnostic.
    public var code: String
    /// Whether the code is authoritative enough for policy decisions.
    public var authority: Authority

    /// Records a close code and the substrate's confidence in its interpretation.
    /// - Parameters:
    ///   - code: Stable denial or close code.
    ///   - authority: Defaults to authoritative for structured close mechanisms.
    public init(code: String, authority: Authority = .authoritative) {
        self.code = code
        self.authority = authority
    }
}

/// One side of one live peer connection: independent named lanes (5.2) that
/// all die together with the connection (5.4).
public protocol PeerConnection: AnyObject, Sendable {
    /// The key this connection's encryption layer PROVED the remote peer
    /// holds (iroh authenticates the endpoint key; the tailnet substrate will
    /// authenticate a device certificate derived from the same identity).
    /// nil only when the substrate has no transport identity (loopback).
    /// When present, admission trusts THIS and never a self-reported hello
    /// field (contract 3.5).
    var authenticatedRemoteKey: Data? { get async }
    /// Obtains the independently flow-controlled lane for a logical name.
    /// - Parameter name: Application lane name shared with the remote peer.
    /// - Returns: The connection-owned lane; an ended connection cannot revive it.
    func lane(_ name: String) async -> any TransportLane
    /// Close, embedding the reason in the substrate's own close mechanism.
    /// NEVER preceded by a sleep: the reason channel is the delivery
    /// guarantee, not time (contract 3.3).
    /// - Parameter reason: Optional stable close cause conveyed to the peer.
    func closeAll(reason: ConnectionTermination?) async
    /// Why this connection ended. Await only after observing the connection
    /// end (a lane EOF); resolves once the termination cause is known. A
    /// connection watcher may call this before a lane ends; that form waits
    /// for the substrate's native close signal.
    /// - Returns: The substrate's attributed close cause, if available.
    func termination() async -> ConnectionTermination?
    /// Classifies a lane EOF without waiting for the whole connection to
    /// close. Substrates with an independent native close cause should return
    /// it when already available and otherwise return nil promptly.
    func terminationAfterLaneEOF() async -> ConnectionTermination?
    /// Whether this connection has reached its terminal closed state.
    var isClosed: Bool { get async }
}

extension PeerConnection {
    /// Substrates without a distinct lane-EOF observation retain their
    /// original termination behavior.
    public func terminationAfterLaneEOF() async -> ConnectionTermination? {
        await termination()
    }

    /// Closes every lane without attaching an application close reason.
    public func closeAll() async {
        await closeAll(reason: nil)
    }
}

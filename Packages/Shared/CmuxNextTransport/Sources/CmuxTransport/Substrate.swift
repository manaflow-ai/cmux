import Foundation

/// The substrate seam: everything above (admission, sessions, lanes, expiry
/// lifecycle) is written against these two protocols, so the loopback (P0),
/// the iroh substrate (iroh mode, P1), and the tailnet substrate (Tailscale
/// mode) slot in without touching a line of protocol logic. The hard mode
/// switch (contract 2.3) picks which substrate exists; nothing above it knows.

/// One ordered, lossless frame stream (contract 5.1). One QUIC stream in the
/// real substrates. A slow lane suspends its own sender only (5.3).
public protocol TransportLane: Sendable {
    var name: String { get }
    func send(_ frame: Frame) async throws
    func receive() async -> Frame?
    /// How many times a send suspended on backpressure (contract 8.2).
    var backpressureStalls: Int { get async }
}

/// `for await frame in lane.frames`: AsyncSequence sugar over receive() with
/// identical pull semantics (no extra buffering), ending on lane close or on
/// task cancellation. Lanes are SINGLE-CONSUMER: run exactly one read loop
/// per lane end; two concurrent loops would split the frames between them.
public struct LaneFrames: AsyncSequence, Sendable {
    public typealias Element = Frame
    let lane: any TransportLane

    public struct AsyncIterator: AsyncIteratorProtocol {
        let lane: any TransportLane

        public mutating func next() async -> Frame? {
            await lane.receive()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(lane: lane)
    }
}

extension TransportLane {
    public var frames: LaneFrames { LaneFrames(lane: self) }
}

/// Why a connection ended, carried by the SUBSTRATE's own close mechanism
/// (QUIC CONNECTION_CLOSE code + reason bytes on iroh; stored on the wire in
/// loopback), so denials and attributed closes arrive without any timing
/// dependence (contract 3.3, 4.4). The code namespace is shared with
/// DenialCode.rawValue and CloseReason.code.
public struct ConnectionTermination: Sendable, Equatable {
    public var code: String

    public init(code: String) { self.code = code }
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
    func lane(_ name: String) async -> any TransportLane
    /// Close, embedding the reason in the substrate's own close mechanism.
    /// NEVER preceded by a sleep: the reason channel is the delivery
    /// guarantee, not time (contract 3.3).
    func closeAll(reason: ConnectionTermination?) async
    /// Why this connection ended. Await only after observing the connection
    /// end (a lane EOF); resolves once the termination cause is known.
    func termination() async -> ConnectionTermination?
    var isClosed: Bool { get async }
}

extension PeerConnection {
    public func closeAll() async {
        await closeAll(reason: nil)
    }
}

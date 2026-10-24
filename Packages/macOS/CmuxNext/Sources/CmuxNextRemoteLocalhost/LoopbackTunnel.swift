public import Foundation

/// What a tunnel to the machine's loopback delivers, in order.
public enum LoopbackTunnelEvent: Sendable, Equatable {
    case data(Data)
    /// The target ended its side.
    case eof
    /// Over; `error` describes an early end (connection lost, reset).
    case closed(error: String?)
}

/// One byte stream to a loopback port of a machine. The App adapts the
/// daemon client's `LoopbackStream` to it, so this module never imports
/// the daemon module.
public protocol LoopbackTunnel: Sendable {
    var events: AsyncStream<LoopbackTunnelEvent> { get }
    /// Waits while the machine's window is spent.
    func write(_ data: Data) async throws
    /// Received bytes were written on (returns flow-control credit).
    func consumed(_ count: Int)
    func shutdownWrite()
    func close()
}

/// Pulls one tunnel's bytes a read at a time for a client that reads on demand (Open Desktop's
/// native viewer), returning flow-control credit for each read. One reader per tunnel.
public actor LoopbackTunnelReader {
    private let tunnel: any LoopbackTunnel
    private var iterator: AsyncStream<LoopbackTunnelEvent>.Iterator?

    public init(_ tunnel: any LoopbackTunnel) {
        self.tunnel = tunnel
        iterator = tunnel.events.makeAsyncIterator()
    }

    /// The next bytes; nil at the end of the stream. Throws when the tunnel ended early.
    public func read() async throws -> Data? {
        guard var events = iterator else { return nil }
        let event = await events.next()
        iterator = events
        switch event {
        case .data(let data)?:
            tunnel.consumed(data.count)
            return data
        case .closed(let error?)?:
            iterator = nil
            throw LoopbackTunnelFailure.other(error)
        case .eof?, .closed(nil)?, nil:
            iterator = nil
            return nil
        }
    }
}

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

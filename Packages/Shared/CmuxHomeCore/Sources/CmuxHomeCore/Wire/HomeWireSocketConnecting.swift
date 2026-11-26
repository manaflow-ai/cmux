public import Foundation

/// Opens sockets for `WireHomeSource` (one per stream connection).
public protocol HomeWireSocketConnecting: Sendable {
    /// A new socket for `request` (its URL, headers and subprotocol are set);
    /// it connects as soon as it is made.
    func connect(_ request: URLRequest) -> any HomeWireSocket
}

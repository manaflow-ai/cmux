/// The attributed kind of the path currently carrying a connection.
public enum IrxCarrierPathKind: Sendable, Equatable {
    /// Packets flow peer to peer with no intermediary.
    case direct
    /// Packets flow through a relay server.
    case relay
    /// The carrier could not attribute the path.
    case unknown
}

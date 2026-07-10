/// Selects whether Iroh may choose an ephemeral UDP port or must bind one address.
public enum CmxIrohEndpointBindPolicy: Equatable, Sendable {
    /// Uses Iroh's default dual-stack sockets with OS-assigned ports.
    case ephemeral

    /// Requires the exact IP address and port. A collision fails endpoint activation.
    case required(CmxIrohBindAddress)

    var socketAddress: String? {
        switch self {
        case .ephemeral:
            nil
        case let .required(address):
            address.socketAddress
        }
    }
}

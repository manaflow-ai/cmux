/// The status reported by the system VPN, independent of the terminal tunnel.
public enum CloudSystemVPNPhase: Sendable, Equatable {
    case off
    case preparing
    case connecting
    case connected
    case disconnecting
    case failed(CloudSystemVPNError)
}

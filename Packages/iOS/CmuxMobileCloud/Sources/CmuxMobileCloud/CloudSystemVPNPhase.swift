/// The optional system VPN's state, independent of the in-process terminal
/// tunnel.
public enum CloudSystemVPNPhase: Sendable, Equatable {
    /// No VPN is running (it may still be saved in Settings).
    case off
    /// Registering this device's VPN peer with Cloud.
    case preparing
    /// iOS is bringing the tunnel up.
    case connecting
    /// Other apps can reach Cloud private addresses.
    case connected
    /// iOS is tearing the tunnel down.
    case disconnecting
    /// The last change failed.
    case failed(CloudSystemVPNError)

    /// Whether the user's switch reads on: requested, coming up, or up.
    public var isRequestedOn: Bool {
        switch self {
        case .preparing, .connecting, .connected: true
        case .off, .disconnecting, .failed: false
        }
    }

    /// Whether a change is in flight, during which the switch is not
    /// actionable.
    public var isTransitioning: Bool {
        switch self {
        case .preparing, .connecting, .disconnecting: true
        case .off, .connected, .failed: false
        }
    }
}

/// Why a system VPN change failed. Never carries configuration text or keys.
public enum CloudSystemVPNError: Error, Sendable, Equatable {
    /// iOS refused to save the VPN, usually because the consent prompt was
    /// declined.
    case permissionRequired
    /// This device cannot run a packet tunnel (the Simulator).
    case unavailable
    /// The saved VPN could not be written, started or validated.
    case configuration
    /// Cloud could not register this device's VPN peer.
    case enrollment
}

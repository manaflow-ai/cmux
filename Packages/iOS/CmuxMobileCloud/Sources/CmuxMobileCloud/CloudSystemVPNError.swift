/// Safe failures that never contain enrollment configuration or private keys.
public enum CloudSystemVPNError: Error, Sendable, Equatable {
    case permissionRequired
    case unavailable
    case configuration
    case enrollment

    /// Cloud registration failures happen before a VPN can be saved in Settings.
    public var offersSettingsRecovery: Bool {
        switch self {
        case .permissionRequired, .configuration: true
        case .unavailable, .enrollment: false
        }
    }
}

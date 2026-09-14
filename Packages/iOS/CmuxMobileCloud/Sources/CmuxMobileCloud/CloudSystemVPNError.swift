/// Safe failures that never contain enrollment configuration or private keys.
public enum CloudSystemVPNError: Error, Sendable, Equatable {
    case permissionRequired
    case unavailable
    case configuration
    case enrollment
}

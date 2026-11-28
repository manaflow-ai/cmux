/// An application's effective authorization for one Simulator permission.
public enum SimulatorPrivacyAuthorization: String, Codable, CaseIterable, Hashable, Sendable {
    /// The application has not made a choice and will be prompted.
    case notDetermined
    /// Access is denied.
    case denied
    /// Access is granted.
    case granted
    /// Photos access is limited to selected items.
    case limited
    /// Notifications include critical-alert authorization.
    case critical
    /// The active runtime did not expose a readable value.
    case unknown
}

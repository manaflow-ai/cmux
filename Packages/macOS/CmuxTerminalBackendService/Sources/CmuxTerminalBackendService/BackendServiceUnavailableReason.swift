/// A stable, sendable explanation for backend unavailability.
public enum BackendServiceUnavailableReason: Equatable, Sendable {
    /// A required bundle artifact is absent or unusable.
    case missingBundleItem(BackendServiceMissingBundleItem)

    /// ServiceManagement could not resolve the bundled launch agent.
    case serviceNotFound

    /// ServiceManagement rejected registration.
    case registrationFailed

    /// ServiceManagement rejected unregistration.
    case unregistrationFailed

    /// The launch agent was eligible, but its protocol handshake failed.
    case readinessFailed
}

/// The observable result of one persistent-backend bootstrap attempt.
public enum BackendServiceBootstrapResult: Equatable, Sendable {
    /// The feature gate is off, so no bundle or service state was touched.
    case disabled

    /// The running launch agent completed the expected protocol handshake.
    case ready(BackendServiceReadiness)

    /// The user must approve the launch agent in System Settings.
    case requiresApproval

    /// A required app-bundle artifact was absent or unusable.
    case missingBundleItem(BackendServiceMissingBundleItem)

    /// ServiceManagement could not resolve the bundled launch agent.
    case serviceNotFound

    /// The eligible launch agent did not complete a valid protocol handshake.
    case backendUnavailable
}

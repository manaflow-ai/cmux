/// The service-management state relevant to backend bootstrap.
public enum BackendServiceStatus: Equatable, Sendable {
    /// The launch agent has not been registered.
    case notRegistered

    /// The launch agent is enabled and launchd owns its lifecycle.
    case enabled

    /// The user must approve the launch agent in System Settings.
    case requiresApproval

    /// ServiceManagement could not locate the app-bundled launch agent.
    case notFound
}

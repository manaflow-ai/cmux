/// Observable lifecycle state for the app-bundled persistent backend.
public enum BackendServiceRuntimeState: Equatable, Sendable {
    /// The build gate is disabled.
    case disabled

    /// Bundle inspection and service status lookup are running.
    case checking

    /// The running service completed the expected protocol handshake.
    case ready(BackendServiceReadiness)

    /// The service is eligible to launch but has not completed its handshake.
    case launching

    /// The service is waiting for user approval in System Settings.
    case requiresApproval

    /// The service cannot currently become available.
    case unavailable(BackendServiceUnavailableReason)

    /// Unregistration is terminating the backend and its PTYs.
    case unregistering

    /// The service is not registered.
    case unregistered
}

/// A registration seam for the app-bundled persistent terminal backend.
public protocol BackendServiceRegistration: Sendable {
    /// The current service-management status.
    func status() async -> BackendServiceStatus

    /// Submits the bundled launch agent for registration.
    ///
    /// - Throws: The underlying service-management registration error.
    func register() async throws

    /// Unregisters the launch agent and waits for its process to terminate.
    ///
    /// Unregistration terminates every PTY owned by the backend process.
    ///
    /// - Throws: The underlying service-management unregistration error.
    func unregister() async throws

    /// Opens System Settings at the Login Items service-approval UI.
    func openSystemSettingsLoginItems() async
}

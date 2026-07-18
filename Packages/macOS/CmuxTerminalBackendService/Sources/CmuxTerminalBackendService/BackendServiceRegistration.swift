/// A registration seam for the app-bundled persistent terminal backend.
public protocol BackendServiceRegistration: Sendable {
    /// Validates and atomically stages the pair shipped by the current app.
    func prepareBundledPair() async throws -> BackendServiceInstalledPair

    /// The current service-management status.
    func status() async throws -> BackendServiceStatus

    /// Returns a freshly validated descriptor for the daemon path loaded by launchd.
    func activeInstalledPair() async throws -> BackendServiceInstalledPair?

    /// Ensures that a validated immutable launch agent is registered.
    ///
    /// A concurrently registered valid pair wins. This operation never replaces
    /// an already loaded descriptor merely to select the caller's staged pair.
    ///
    /// - Throws: The underlying service-management registration error.
    func register(_ pair: BackendServiceInstalledPair) async throws

    /// Activates a staged pair only when no daemon descriptor is loaded.
    ///
    /// A live vN is always deferred. Callers must first complete an explicit
    /// safe or idle handoff that leaves the service stopped.
    func activateIfServiceStopped(
        _ pair: BackendServiceInstalledPair
    ) async throws -> BackendServicePairActivationResult

    /// Unregisters the launch agent and waits for its process to terminate.
    ///
    /// Unregistration terminates every PTY owned by the backend process.
    ///
    /// - Throws: The underlying service-management unregistration error.
    func unregister() async throws

    /// Opens System Settings at the Login Items service-approval UI.
    func openSystemSettingsLoginItems() async
}

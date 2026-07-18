internal import ServiceManagement

/// Registers an app-bundled launch agent through `SMAppService`.
public actor SystemBackendServiceRegistration: BackendServiceRegistration {
    private let service: SMAppService

    /// Creates a registration adapter for a bundled property-list filename.
    ///
    /// - Parameter propertyListName: The filename below
    ///   `Contents/Library/LaunchAgents`.
    public init(propertyListName: String) {
        service = SMAppService.agent(plistName: propertyListName)
    }

    /// The normalized `SMAppService` status.
    public func status() -> BackendServiceStatus {
        switch service.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .notFound
        }
    }

    /// Registers the launch agent without unregistering an existing service.
    ///
    /// - Throws: The underlying `SMAppService.register()` error.
    public func register() throws {
        try service.register()
    }

    /// Unregisters the launch agent and waits until launchd has terminated it.
    ///
    /// - Throws: The underlying `SMAppService.unregister` error.
    public func unregister() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            service.unregister { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Opens System Settings at the Login Items service-approval UI.
    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

import struct CmuxSafeConcurrency.OwnerReference
import CmuxNextDaemonService

/// A service's non-owning reference back to the app's `AppServices`, which owns it (p10-stability-091): an
/// `OwnerReference`, so a read after the services are gone reports once per site and gives nil, and the caller
/// refuses (an action throws ``closing``) or does nothing. In the app `AppProcessRoot` holds the services until exit,
/// so a miss is a bug; a test that builds its own services frees them, and every service under them, when it lets
/// them go.
nonisolated struct AppServicesReference: Sendable {
    /// What an action refuses with when the services are gone.
    static var closing: ActionFailure { ActionFailure(message: closingReason) }
    /// The refusal's text, for a call that answers with a reason instead of throwing.
    static var closingReason: String { RefusalStrings.appClosing }

    private let reference: OwnerReference<AppServices>

    init(_ services: AppServices) {
        reference = OwnerReference(services, invariant: "app-services-outlive-their-services")
    }

    /// The services, or nil after reporting this site's first miss of the launch.
    func resolve(fileID: StaticString = #fileID, line: UInt = #line) -> AppServices? {
        reference.resolve(fileID: fileID, line: line)
    }
}

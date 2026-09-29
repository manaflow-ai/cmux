/// The platform boundary for installing and observing the system VPN.
///
/// The app satisfies it with Network Extension preferences; tests pass a fake.
@MainActor
public protocol CloudSystemVPNManaging: AnyObject {
    /// Whether this device can run a packet tunnel at all.
    var isAvailable: Bool { get }
    /// The live status iOS reports.
    var phase: CloudSystemVPNPhase { get }
    /// Called on every status change iOS reports, including ones made from
    /// Settings while the app runs.
    var onPhaseChange: (@MainActor (CloudSystemVPNPhase) -> Void)? { get set }
    /// Loads the saved VPN, removing it when it belongs to another account.
    func refresh(scope: String) async throws
    /// Loads the saved VPN, removing it when it belongs to another account
    /// or team.
    func refresh(scope: String, teamID: String?) async throws
    /// Saves the configuration (iOS asks for consent the first time) and
    /// starts it.
    func installAndStart(configuration: String, scope: String) async throws
    /// Saves and starts a profile owned by `scope` and `teamID`.
    func installAndStart(configuration: String, scope: String, teamID: String?) async throws
    /// Makes a best-effort synchronous request to stop an operation that has
    /// exceeded its deadline.
    func cancelPendingOperation()
    /// Stops the VPN, and optionally removes it and its secret.
    func stop(removeConfiguration: Bool) async throws
}

public extension CloudSystemVPNManaging {
    func refresh(scope: String, teamID: String?) async throws {
        try await refresh(scope: scope)
    }

    func installAndStart(configuration: String, scope: String, teamID: String?) async throws {
        try await installAndStart(configuration: configuration, scope: scope)
    }
}

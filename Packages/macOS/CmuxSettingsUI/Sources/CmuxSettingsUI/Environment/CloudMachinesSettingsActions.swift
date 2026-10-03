import Foundation

/// Host callbacks used by the Cloud Machines Settings section.
@MainActor
public protocol CloudMachinesSettingsActions: AnyObject {
    /// Whether rollout and managed policy expose Cloud on this Mac.
    var isCloudMachinesAvailable: Bool { get }
    /// Whether the activation marker and rollout currently admit operations.
    var isCloudMachinesEnabled: Bool { get }
    /// The shared first-use setup state.
    var cloudMachinesActivationState: CloudMachinesActivationState { get }
    /// Starts the shared first-use setup operation.
    func enableCloudMachines()
    /// Cancels an in-flight first-use setup operation.
    func cancelCloudMachinesActivation()
    /// Retries the shared setup operation after a failed or cancelled attempt.
    func retryCloudMachinesActivation()
    /// Disables Cloud while preserving its persisted identities and settings.
    func disableCloudMachines()
    /// Emits the current state and every later state transition.
    func cloudMachinesActivationUpdates() -> AsyncStream<CloudMachinesActivationState>
    /// Starts account sign-in after an expired or missing session.
    func signInForCloudMachines()
    /// The caller's machine plan, or nil when it is not available.
    func cloudMachinesPlanSummary() async -> CloudMachinesPlanSummary?
    /// Whether the signed-in account's plan includes Cloud before it is
    /// enabled: true for Pro and Max, false for Free, nil when signed out or
    /// the plan could not be loaded (enable then lets the server decide).
    func cloudMachinesPlanIncludesCloud() async -> Bool?
    /// The signed-in account's id (observable), so Settings re-checks the
    /// plan when the user signs in, signs out or switches accounts.
    var cloudMachinesAccountID: String? { get }
    /// Reveals the right-sidebar Machines panel.
    func openCloudMachinesPanel()
    /// Opens the optional system-wide VPN setup flow.
    func openCloudVPNSetup()
    /// Opens the host's plan management / upgrade flow.
    func openCloudMachinesBilling()
}

public extension CloudMachinesSettingsActions {
    /// Fail-closed defaults for previews and package-only hosts.
    var isCloudMachinesAvailable: Bool { false }
    var isCloudMachinesEnabled: Bool { false }
    var cloudMachinesActivationState: CloudMachinesActivationState { .unavailable }
    func enableCloudMachines() {}
    func cancelCloudMachinesActivation() {}
    func retryCloudMachinesActivation() {}
    func disableCloudMachines() {}
    func cloudMachinesActivationUpdates() -> AsyncStream<CloudMachinesActivationState> {
        AsyncStream { $0.yield(.unavailable); $0.finish() }
    }
    func cloudMachinesPlanIncludesCloud() async -> Bool? { nil }
    var cloudMachinesAccountID: String? { nil }
    func signInForCloudMachines() {}
    func cloudMachinesPlanSummary() async -> CloudMachinesPlanSummary? { nil }
    func openCloudMachinesPanel() {}
    func openCloudVPNSetup() {}
    func openCloudMachinesBilling() {}
}

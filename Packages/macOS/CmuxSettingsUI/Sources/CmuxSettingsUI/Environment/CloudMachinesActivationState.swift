import Foundation

/// The first-use Cloud Machines state exposed to Settings without importing the
/// app's activation coordinator.
public enum CloudMachinesActivationState: Equatable, Sendable {
    /// Cloud is available but has not completed first-use setup.
    case disabled
    /// The shared setup operation is currently running.
    case enabling
    /// Cloud setup completed and Cloud machines may be used.
    case enabled
    /// Setup failed for a recoverable account or service reason.
    case failed(CloudMachinesActivationFailure)
    /// The user cancelled setup before it completed.
    case cancelled
    /// Rollout or managed policy makes Cloud unavailable on this Mac.
    case unavailable

    /// Whether Cloud machine operations are ready for use.
    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }
}

/// A recoverable reason first-use Cloud setup can fail.
public enum CloudMachinesActivationFailure: Equatable, Sendable {
    /// The signed-in team needs a paid plan for Cloud machines.
    case requiresPro
    /// The account session is missing or expired.
    case signInRequired
    /// The Cloud service could not complete setup.
    case serviceUnavailable
}

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
    func signInForCloudMachines() {}
    func cloudMachinesPlanSummary() async -> CloudMachinesPlanSummary? { nil }
    func openCloudMachinesPanel() {}
    func openCloudVPNSetup() {}
    func openCloudMachinesBilling() {}
}

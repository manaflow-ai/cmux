import Foundation

/// Publishes one daemon profile's tool admission from that profile's own
/// helper-owned TCC evidence.
///
/// An agent call is admitted exactly when Computer Use is enabled and the
/// profile's current helper generation reports both grants. The durable
/// onboarding record is presentation history, so it does not gate admission,
/// and a probe that failed to answer never deletes it. Only an answered status
/// that denies a grant invalidates the record.
@MainActor
public struct ComputerUseProfileAdmissionCoordinator {
    /// The outcome of one publication attempt.
    public struct Outcome: Equatable, Sendable {
        /// Whether the daemon acknowledged the published value.
        public let acknowledged: Bool
        /// The value published to the daemon.
        public let ready: Bool
        /// The helper's answer, or `nil` when the probe did not answer.
        public let status: ComputerUsePermissionStatus?
    }

    public let store: ComputerUseOnboardingStore
    public let isEnabled: @MainActor () -> Bool
    public let probe: @MainActor (ComputerUseDaemonProfile) async -> ComputerUsePermissionStatus?
    public let publish: @MainActor (ComputerUseDaemonProfile, Bool) async -> Bool

    /// Creates a coordinator over injected probe and publication transports.
    public init(
        store: ComputerUseOnboardingStore,
        isEnabled: @escaping @MainActor () -> Bool,
        probe: @escaping @MainActor (ComputerUseDaemonProfile) async -> ComputerUsePermissionStatus?,
        publish: @escaping @MainActor (ComputerUseDaemonProfile, Bool) async -> Bool
    ) {
        self.store = store
        self.isEnabled = isEnabled
        self.probe = probe
        self.publish = publish
    }

    /// Probes `profile` and publishes its readiness. Other profiles are not read.
    public func admit(_ profile: ComputerUseDaemonProfile) async -> Outcome {
        let status = await probe(profile)
        if status?.confirmsRevocation == true,
           store.completionCommitted || store.phase.isReady {
            store.invalidateCompletion()
        }
        let ready = isEnabled() && status?.grantsHeld == true
        let acknowledged = await publish(profile, ready)
        return Outcome(acknowledged: acknowledged, ready: ready, status: status)
    }
}

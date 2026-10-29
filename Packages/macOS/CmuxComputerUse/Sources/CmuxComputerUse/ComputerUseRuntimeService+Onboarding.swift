import Foundation

/// Host-only setup admission coordinated with both authenticated daemon profiles.
extension ComputerUseRuntimeService {
    /// Coordinates durable completion with readiness publication.
    public var onboardingAdmission: ComputerUseOnboardingAdmissionCoordinator {
        ComputerUseOnboardingAdmissionCoordinator(
            store: onboarding,
            publish: { await self.publishExternalPermissionReadiness(for: $0) },
            stop: { _ = await self.stopDaemon() }
        )
    }
}

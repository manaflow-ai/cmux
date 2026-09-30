import CmuxCloud
import CmuxSettings

extension CmuxTuiSurfaceProviderRegistry {
    /// Completes the readiness work that the former Beta Features toggle
    /// triggered. The shared hub actor joins concurrent callers to one startup
    /// task, so first-use enablement has one setup owner.
    func prepareForActivation() async throws {
        guard !isRetired, !ManagedDevicePolicy().isEnforced(.disableCloud), isCloudEnabled() else {
            throw VMClientError.cloudMachinesDisabled
        }
        syncPollingToActivationPolicy()
        guard hasCloudSession(), let wireGuardHub else { return }
        try await wireGuardHub.prewarm()
    }
}

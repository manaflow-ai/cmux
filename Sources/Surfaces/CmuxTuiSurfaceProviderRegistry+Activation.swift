import CmuxCloud
import CmuxSettings

extension CmuxTuiSurfaceProviderRegistry {
    /// Completes the readiness work that the former Beta Features toggle
    /// triggered. The shared hub actor joins concurrent callers to one startup
    /// task, so first-use enablement has one setup owner.
    func prepareForActivation() async throws {
        guard !ManagedDevicePolicy().isEnforced(.disableCloud), CloudMachinesFeature.isAvailable else {
            throw VMClientError.cloudMachinesDisabled
        }
        guard hasCloudSession() else { throw VMClientError.notSignedIn }
        guard !isRetired else { throw VMClientError.cloudMachinesDisabled }
        let accessEpoch = self.accessEpoch
        guard let client = VMClient.shared else {
            throw VMClientError.malformedResponse("Cloud VM client is not available.")
        }

        // Capture the authenticated team scope once. VMClient fences both the
        // list and any activation-only enrollment against this value, so a
        // sign-out or team switch during setup cannot commit another account's
        // readiness as this activation.
        guard let expectedTeamScope = AppDelegate.shared?.auth?.coordinator.authenticatedTeamScope else {
            throw VMClientError.notSignedIn
        }
        _ = try await client.listPage(
            allowWhenCloudDisabled: true,
            expectedTeamScope: expectedTeamScope
        )
        try Task.checkCancellation()
        guard !isRetired, self.accessEpoch == accessEpoch, hasCloudSession() else {
            throw VMClientError.notSignedIn
        }
        if AppDelegate.shared?.auth?.coordinator.authenticatedTeamScope != expectedTeamScope {
            throw VMClientError.notSignedIn
        }
        guard let wireGuardHub else { throw VMClientError.cloudMachinesDisabled }
        _ = try await wireGuardHub.prewarm(
            allowWhenCloudDisabled: true,
            expectedTeamScope: expectedTeamScope
        )
        try Task.checkCancellation()
        guard !isRetired, self.accessEpoch == accessEpoch, hasCloudSession() else {
            throw VMClientError.notSignedIn
        }
        if AppDelegate.shared?.auth?.coordinator.authenticatedTeamScope != expectedTeamScope {
            throw VMClientError.notSignedIn
        }
    }

    /// Stops activation-only hub work after cancellation or a failed readiness
    /// attempt. Persisted tunnel identity remains available for the next
    /// retry; no Cloud operation is left running while the marker is off.
    func cancelActivationPreparation() async {
        await wireGuardHub?.stop()
    }
}

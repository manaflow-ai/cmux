import CmuxAuthRuntime
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
        await prepareActivationHub(
            wireGuardHub: wireGuardHub,
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

    /// Runs activation's carrier preparation. Kept as a seam so activation can
    /// be tested independently from the app's live auth and VM client graph.
    func prepareActivationHub(
        wireGuardHub: CloudWireGuardHub?,
        expectedTeamScope: AuthenticatedTeamScope
    ) async {
        // The bundled cmux-tui client is optional. Cloud activation still
        // enables machine creation when this build cannot host the terminal
        // carrier; restored links remain retryable when a present hub is
        // temporarily unavailable. A present hub is also prepared in the
        // background so a missing socket or stale enrollment cannot hold
        // activation open.
        guard let wireGuardHub else { return }
        await wireGuardHub.prepareForCloudUse(
            allowWhenCloudDisabled: true,
            expectedTeamScope: expectedTeamScope
        )
    }

    /// Stops activation-only hub work after cancellation or a failed readiness
    /// attempt. Persisted tunnel identity remains available for the next
    /// retry; no Cloud operation is left running while the marker is off.
    func cancelActivationPreparation() async {
        // Cancel and await this activation's background task before releasing
        // its claim. Other Cloud link leases remain owned by the shared hub.
        await wireGuardHub?.cancelPreparation()
    }
}

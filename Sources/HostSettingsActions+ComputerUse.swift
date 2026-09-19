import CmuxSettingsUI

/// Settings reads the host admission state and opens setup only on an explicit action.
extension HostSettingsActions {
    func refreshComputerUsePermissions() async {
        _ = await computerUseRuntimeService.refreshHelperStatus()
    }

    func computerUseAccessibilityGranted() -> Bool {
        computerUseRuntimeService.status().accessibility
    }

    func computerUseScreenRecordingGranted() -> Bool {
        computerUseRuntimeService.status().screenRecording
    }

    func computerUsePermissionStatusIsKnown() -> Bool {
        computerUseRuntimeService.permissionStatusIsKnown
    }

    func requestComputerUseAccessibility() {
        runComputerUseOnboardingAction(.accessibility)
    }

    func requestComputerUseScreenRecording() {
        runComputerUseOnboardingAction(.screenRecording)
    }

    func openComputerUseAccessibilitySettings() {
        runComputerUseOnboardingAction(.accessibility)
    }

    func openComputerUseScreenRecordingSettings() {
        runComputerUseOnboardingAction(.screenRecording)
    }

    func setRunComputerUseOnboardingAction(
        _ action: @escaping @MainActor (ComputerUseOnboardingWindowController.StartingPoint) -> Void
    ) {
        runComputerUseOnboardingAction = action
    }

    func computerUseSetupStatus() -> ComputerUseSetupStatus {
        let status = computerUseRuntimeService.status()
        return ComputerUseSetupStatus(
            enabled: computerUseRuntimeService.desiredEnabled,
            helperAvailable: computerUseRuntimeService.setupStatusIsKnown,
            accessibilityGranted: status.accessibility,
            screenRecordingGranted: status.screenRecording,
            captureVerified: computerUseRuntimeService.onboardingIsComplete
        )
    }

    func finishComputerUseSetup() {
        runComputerUseOnboardingAction(computerUseRuntimeService.status().accessibility ? .screenRecording : .accessibility)
    }

    func computerUseSetupUpdates() -> AsyncStream<Void> {
        computerUseRuntimeService.onboarding.updates()
    }
}

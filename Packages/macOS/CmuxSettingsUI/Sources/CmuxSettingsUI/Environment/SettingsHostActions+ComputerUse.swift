/// Fail-closed Computer Use defaults for previews and hosts without a helper.
public extension SettingsHostActions {
    /// Default no-op for hosts without Computer Use permission reporting.
    func refreshComputerUsePermissions() async {}
    /// Default denied Accessibility status for hosts without Computer Use.
    func computerUseAccessibilityGranted() -> Bool { false }
    /// Default denied Screen Recording status for hosts without Computer Use.
    func computerUseScreenRecordingGranted() -> Bool { false }
    /// Default unknown status for hosts without Computer Use permission reporting.
    func computerUsePermissionStatusIsKnown() -> Bool { false }
    /// Default no-op for hosts that cannot request Computer Use Accessibility.
    func requestComputerUseAccessibility() {}
    /// Default no-op for hosts that cannot request Computer Use Screen Recording.
    func requestComputerUseScreenRecording() {}
    /// Default no-op for hosts without a Computer Use Accessibility settings route.
    func openComputerUseAccessibilitySettings() {}
    /// Default no-op for hosts without a Computer Use Screen Recording settings route.
    func openComputerUseScreenRecordingSettings() {}
    /// Default unavailable setup state for hosts without Computer Use.
    func computerUseSetupStatus() -> ComputerUseSetupStatus { .unavailable }
    /// No live status changes are available in previews and unsupported hosts.
    func computerUseSetupUpdates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    /// Default no-op for hosts without Computer Use setup.
    func finishComputerUseSetup() {}
}

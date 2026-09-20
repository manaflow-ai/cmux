import Foundation

/// One runtime-owned view of Computer Use enablement and setup evidence.
public struct ComputerUseSettingsSnapshot: Equatable, Sendable {
    public let enabled: Bool
    public let status: ComputerUseSetupStatus
    public let accessibilityGranted: Bool
    public let screenRecordingGranted: Bool
    public let permissionStatusIsKnown: Bool

    public init(
        enabled: Bool,
        status: ComputerUseSetupStatus,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        permissionStatusIsKnown: Bool
    ) {
        self.enabled = enabled
        self.status = status
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.permissionStatusIsKnown = permissionStatusIsKnown
    }
}

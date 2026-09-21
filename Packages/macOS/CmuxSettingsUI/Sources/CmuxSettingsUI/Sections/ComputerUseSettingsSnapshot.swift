import Foundation

/// One runtime-owned view of Computer Use enablement and setup evidence.
nonisolated public struct ComputerUseSettingsSnapshot: Equatable, Sendable {
    /// Effective enablement from the runtime owner.
    public let enabled: Bool
    /// Runtime-owned setup phase projected for Settings.
    public let status: ComputerUseSetupStatus
    /// Current helper-owned Accessibility grant.
    public let accessibilityGranted: Bool
    /// Current helper-owned Screen Recording grant.
    public let screenRecordingGranted: Bool
    /// Whether the helper returned authoritative permission status.
    public let permissionStatusIsKnown: Bool

    /// Creates one internally consistent Settings snapshot.
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

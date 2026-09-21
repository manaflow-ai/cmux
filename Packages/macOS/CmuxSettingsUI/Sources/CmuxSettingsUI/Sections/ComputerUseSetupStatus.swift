import Foundation

/// The host's remaining Computer Use setup step; TCC grants alone are not completion.
nonisolated public enum ComputerUseSetupStatus: Equatable, Sendable {
    /// The user or organization has disabled Computer Use.
    case disabled
    /// The helper could not report authoritative permission status.
    case unavailable
    /// Accessibility permission is missing.
    case accessibilityRequired
    /// Screen Recording permission is missing.
    case screenRecordingRequired
    /// TCC is granted, but explicit direct-capture confirmation remains unverified.
    case captureConfirmationRequired
    /// The helper permissions and host-owned setup verification are complete.
    case ready

    /// Projects the host's admission evidence without inferring consent from TCC.
    /// - Parameters:
    ///   - enabled: Whether the host permits Computer Use.
    ///   - helperAvailable: Whether permission status is authoritative.
    ///   - accessibilityGranted: The helper's Accessibility grant.
    ///   - screenRecordingGranted: The helper's Screen Recording grant.
    ///   - captureVerified: Whether this helper's explicit capture setup completed.
    public init(
        enabled: Bool,
        helperAvailable: Bool,
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        captureVerified: Bool
    ) {
        if !enabled { self = .disabled }
        else if !helperAvailable { self = .unavailable }
        else if !accessibilityGranted { self = .accessibilityRequired }
        else if !screenRecordingGranted { self = .screenRecordingRequired }
        else if !captureVerified { self = .captureConfirmationRequired }
        else { self = .ready }
    }

    var message: String {
        switch self {
        case .disabled:
            String(localized: "settings.computerUse.setup.disabled", defaultValue: "Enable Computer Use to finish setup.")
        case .unavailable:
            String(localized: "settings.computerUse.setup.unavailable", defaultValue: "Computer Use is unavailable. Retry setup.")
        case .accessibilityRequired:
            String(localized: "settings.computerUse.setup.accessibility", defaultValue: "Accessibility permission is required.")
        case .screenRecordingRequired:
            String(localized: "settings.computerUse.setup.screenRecording", defaultValue: "Screen Recording permission is required.")
        case .captureConfirmationRequired:
            String(localized: "settings.computerUse.setup.capture", defaultValue: "Permissions are granted. Finish setup to confirm screen capture with macOS.")
        case .ready:
            String(localized: "settings.computerUse.setup.ready", defaultValue: "Setup is complete. Computer Use is ready.")
        }
    }
}

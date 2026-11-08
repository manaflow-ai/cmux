import Foundation

/// Mac-owned policy for forwarding local agent notifications to mobile devices.
public struct MobilePhonePushSettingsSnapshot: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Hashable, Sendable {
        case onlyWhenAway
        case always
    }

    public let forwardingEnabled: Bool
    public let mode: Mode
    public let hideContent: Bool

    public init(
        forwardingEnabled: Bool,
        mode: Mode,
        hideContent: Bool
    ) {
        self.forwardingEnabled = forwardingEnabled
        self.mode = mode
        self.hideContent = hideContent
    }

    public static let defaultValue = Self(
        forwardingEnabled: true,
        mode: .always,
        hideContent: false
    )
}

/// One partial update applied by the host's authoritative push-settings owner.
public enum MobilePhonePushSettingsMutation: Equatable, Sendable {
    case forwardingEnabled(Bool)
    case mode(MobilePhonePushSettingsSnapshot.Mode)
    case hideContent(Bool)
}

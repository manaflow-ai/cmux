import Foundation

/// OS-enforced protection attached when a secret is first inserted.
public enum MobileRemoteSecretProtection: Equatable, Sendable {
    /// Available only after unlock and never migrated through device backup or iCloud.
    case whenUnlockedThisDeviceOnly
    /// Available after unlock with passcode or an enrolled biometric.
    case whenUnlockedThisDeviceOnlyUserPresence
    /// Available after unlock only for the currently enrolled biometric set.
    case whenUnlockedThisDeviceOnlyBiometryCurrentSet
}

/// Whether a credential is kept on one device or included in the encrypted
/// account vault.
public enum MobileRemoteCredentialSyncMode: String, Codable, CaseIterable, Equatable, Sendable {
    /// Kept only by this device.
    case deviceOnly = "device_only"
    /// Explicitly shared with approved vault devices.
    case encryptedVault = "encrypted_vault"
}

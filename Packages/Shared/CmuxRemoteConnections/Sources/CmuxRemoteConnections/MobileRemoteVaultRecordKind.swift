/// Payload domains for encrypted connection-vault records.
public enum MobileRemoteVaultRecordKind: String, Codable, CaseIterable, Sendable {
    /// Private key, password, or another deliberately synchronized credential.
    case credential
    /// Host address, username, routing, and connection preferences.
    case profile
    /// Accepted host public keys and their verification provenance.
    case hostTrust = "host_trust"
    /// Saved commands, which may themselves contain sensitive data.
    case snippet
    /// Preferences explicitly selected for cross-device synchronization.
    case preferences
}

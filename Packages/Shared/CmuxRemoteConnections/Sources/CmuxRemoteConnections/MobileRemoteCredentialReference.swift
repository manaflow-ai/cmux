/// A non-secret reference from a profile to a Keychain or vault item.
public struct MobileRemoteCredentialReference: Codable, Equatable, Identifiable, Sendable {
    /// Stable credential identifier.
    public let id: String
    /// Secret type stored behind this reference.
    public let kind: MobileRemoteCredentialKind
    /// Optional label, treated as private vault data.
    public let displayName: String?
    /// Fingerprint derived from the public key, if applicable.
    public let publicKeyFingerprint: String?
    /// Whether the user selected encrypted credential synchronization.
    public let syncMode: MobileRemoteCredentialSyncMode
    /// Local requested policy; a synchronized value cannot weaken local Keychain access control.
    public let requiresBiometrics: Bool

    /// Creates metadata for a separately stored credential.
    ///
    /// - Parameters:
    ///   - id: Stable item identifier.
    ///   - kind: Credential type.
    ///   - displayName: Optional private label.
    ///   - publicKeyFingerprint: Public-key fingerprint when available.
    ///   - syncMode: Local-only unless explicitly selected for vault sync.
    ///   - requiresBiometrics: Defaults to protected use on this device.
    public init(
        id: String,
        kind: MobileRemoteCredentialKind,
        displayName: String? = nil,
        publicKeyFingerprint: String? = nil,
        syncMode: MobileRemoteCredentialSyncMode = .deviceOnly,
        requiresBiometrics: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.publicKeyFingerprint = publicKeyFingerprint
        self.syncMode = syncMode
        self.requiresBiometrics = requiresBiometrics
    }
}

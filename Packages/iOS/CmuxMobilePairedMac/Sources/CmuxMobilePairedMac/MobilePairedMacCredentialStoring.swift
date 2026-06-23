/// Persistence interface for local paired-Mac reconnect credentials.
public protocol MobilePairedMacCredentialStoring: Sendable {
    /// Store or remove the reconnect credential for one paired Mac.
    /// - Parameters:
    ///   - credential: Credential to persist, or `nil` to remove it.
    ///   - macDeviceID: Stable identifier of the paired Mac.
    ///   - stackUserID: Owning Stack Auth user, if any.
    ///   - teamID: Stack team this pairing belongs to, if any.
    func storeCredential(
        _ credential: MobilePairedMacCredential?,
        macDeviceID: String,
        stackUserID: String?,
        teamID: String?
    ) async throws

    /// Remove every locally persisted reconnect credential while preserving
    /// nonsecret paired-Mac metadata.
    func removeAllCredentials() async throws
}

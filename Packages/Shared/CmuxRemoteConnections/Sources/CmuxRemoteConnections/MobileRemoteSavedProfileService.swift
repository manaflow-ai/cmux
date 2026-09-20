public import Foundation

/// Atomically coordinates encrypted profile metadata with a scoped Keychain secret.
///
/// The profile store owns encrypted host metadata. The secret store owns the
/// password bytes. Saving writes the secret first, then the profile reference,
/// and rolls the secret back when metadata persistence fails. Loading returns
/// short-lived credential material only after both records authenticate.
public actor MobileRemoteSavedProfileService {
    private let profiles: MobileRemoteProfileStore
    private let secrets: any MobileRemoteSecretStore
    private let account: MobileRemoteAuthenticatedAccount
    private let vaultID: UUID
    private let protection: MobileRemoteSecretProtection

    /// Creates a service over already-authenticated local stores.
    /// - Parameters:
    ///   - profiles: Encrypted profile metadata repository.
    ///   - secrets: Exact account-scoped Keychain service.
    ///   - account: Live cmux account identity.
    ///   - vaultID: Stable vault identity used for secret scoping.
    ///   - protection: Keychain access-control policy for new passwords.
    public init(
        profiles: MobileRemoteProfileStore,
        secrets: any MobileRemoteSecretStore,
        account: MobileRemoteAuthenticatedAccount,
        vaultID: UUID,
        protection: MobileRemoteSecretProtection = .whenUnlockedThisDeviceOnlyUserPresence
    ) {
        self.profiles = profiles
        self.secrets = secrets
        self.account = account
        self.vaultID = vaultID
        self.protection = protection
    }

    /// Lists encrypted profile metadata without loading any passwords.
    public func listProfiles() async throws -> [MobileRemoteProfile] {
        try await profiles.profiles()
    }

    /// Saves or replaces a password-backed profile without serializing the password.
    /// - Parameters:
    ///   - profile: Profile with no credential reference or an existing password reference.
    ///   - password: Password consumed only by the Keychain operation.
    /// - Returns: The profile containing the opaque credential reference.
    /// - Throws: Validation, Keychain, profile-store, or cancellation errors.
    public func savePasswordProfile(
        _ profile: MobileRemoteProfile,
        password: String,
        interaction: MobileRemoteSecretInteraction = .nonInteractive
    ) async throws -> MobileRemoteProfile {
        try Task.checkCancellation()
        let credentialID = profile.credentialID ?? UUID()
        let reference = MobileRemoteCredentialReference(
            id: credentialID, kind: .password,
            displayName: profile.name, syncMode: .deviceOnly,
            requiresBiometrics: protection != .whenUnlockedThisDeviceOnly
        )
        let scope = try MobileRemoteSecretScope(
            account: account, vaultID: vaultID, itemID: credentialID
        )
        let value = MobileRemoteSecretValue(text: password)
        let storedProfile = try profile.withCredential(reference)
        if profile.credentialID == nil {
            try await secrets.insert(value, scope: scope, protection: protection)
        } else {
            try await secrets.updateValue(value, scope: scope, interaction: interaction)
        }
        do {
            try await profiles.save(storedProfile)
            return storedProfile
        } catch {
            if profile.credentialID == nil {
                try? await secrets.delete(scope: scope, interaction: .nonInteractive)
            }
            throw error
        }
    }

    /// Loads one profile and its password only after authenticating both stores.
    /// - Parameters:
    ///   - profileID: Opaque profile identifier.
    ///   - interaction: Keychain interaction policy for biometric protection.
    /// - Returns: Profile and transient password material, or nil for absence.
    public func loadPasswordProfile(
        profileID: UUID,
        interaction: MobileRemoteSecretInteraction = .nonInteractive
    ) async throws -> (profile: MobileRemoteProfile, credential: MobileRemoteCredentialMaterial)? {
        guard let profile = try await profiles.profile(id: profileID),
              let credentialID = profile.credentialID else { return nil }
        let scope = try MobileRemoteSecretScope(
            account: account, vaultID: vaultID, itemID: credentialID
        )
        let secret = try await secrets.read(scope: scope, interaction: interaction)
        guard let password = String(data: secret.bytes, encoding: .utf8) else {
            throw MobileRemoteSecretStoreError.corruptedItem(-1)
        }
        return (profile, .password(password))
    }

    /// Deletes profile metadata and its device-local password reference.
    /// - Parameter profileID: Opaque profile identifier.
    /// - Throws: Store, Keychain, or cancellation errors.
    public func remove(profileID: UUID) async throws {
        guard let profile = try await profiles.profile(id: profileID),
              let credentialID = profile.credentialID else {
            try await profiles.remove(id: profileID)
            return
        }
        let scope = try MobileRemoteSecretScope(
            account: account, vaultID: vaultID, itemID: credentialID
        )
        try await profiles.remove(id: profileID)
        try? await secrets.delete(scope: scope, interaction: .nonInteractive)
    }
}

import CryptoKit
public import Foundation

/// App-lifetime account-gated owner of encrypted saved remote profiles.
///
/// The vault key is stored as a device-only Keychain secret under the stable
/// vault identity. Profile metadata is encrypted in SQLite, while passwords
/// remain separate Keychain records managed by
/// ``MobileRemoteSavedProfileService``.
public actor MobileRemoteSavedProfileController: MobileRemoteSavedProfileServing {
    private let accountGate: MobileRemoteAccountGate
    private let namespace: MobileRemoteKeychainNamespace
    private let storageDirectory: URL
    private let vaultID: UUID
    private var cachedService: MobileRemoteSavedProfileService?

    /// Creates a lazy controller; no Keychain or filesystem access occurs yet.
    /// - Parameters:
    ///   - accountGate: Live account authority.
    ///   - namespace: Exact signed Keychain namespace.
    ///   - storageDirectory: Private application-support directory.
    ///   - vaultID: Durable opaque vault identity for this app namespace.
    public init(
        accountGate: MobileRemoteAccountGate,
        namespace: MobileRemoteKeychainNamespace,
        storageDirectory: URL,
        vaultID: UUID
    ) {
        self.accountGate = accountGate
        self.namespace = namespace
        self.storageDirectory = storageDirectory
        self.vaultID = vaultID
    }

    /// Lists saved profiles after authenticating the current account and vault key.
    public func profiles() async throws -> [MobileRemoteProfile] {
        try await service().listProfiles()
    }

    /// Saves a password-backed profile using the device-only vault and Keychain.
    public func savePasswordProfile(
        _ profile: MobileRemoteProfile,
        password: String,
        interaction: MobileRemoteSecretInteraction = .nonInteractive
    ) async throws -> MobileRemoteProfile {
        try await service().savePasswordProfile(
            profile, password: password, interaction: interaction
        )
    }

    /// Loads a saved profile and transient password material.
    public func loadPasswordProfile(
        profileID: UUID,
        interaction: MobileRemoteSecretInteraction = .nonInteractive
    ) async throws -> (profile: MobileRemoteProfile, credential: MobileRemoteCredentialMaterial)? {
        try await service().loadPasswordProfile(profileID: profileID, interaction: interaction)
    }

    /// Removes profile metadata and its exact Keychain password item.
    public func remove(profileID: UUID) async throws {
        try await service().remove(profileID: profileID)
    }

    private func service() async throws -> MobileRemoteSavedProfileService {
        if let cachedService { return cachedService }
        let account = try await accountGate.requireAccount()
        try FileManager.default.createDirectory(
            at: storageDirectory, withIntermediateDirectories: true
        )
        let secrets = MobileRemoteKeychainSecretStore(namespace: namespace)
        let vaultScope = try MobileRemoteSecretScope(
            account: account, vaultID: vaultID, itemID: vaultID
        )
        let vaultKey: SymmetricKey
        do {
            let value = try await secrets.read(scope: vaultScope, interaction: .nonInteractive)
            guard value.bytes.count == 32 else {
                throw MobileRemoteProfileStoreError.corruptRecord
            }
            vaultKey = SymmetricKey(data: value.bytes)
        } catch MobileRemoteSecretStoreError.itemNotFound {
            let generated = SymmetricKey(size: .bits256)
            try await secrets.insert(
                MobileRemoteSecretValue(bytes: generated.withUnsafeBytes { Data($0) }),
                scope: vaultScope,
                protection: .whenUnlockedThisDeviceOnlyUserPresence
            )
            vaultKey = generated
        }
        let accountDigest = SHA256.hash(data: Data(account.accountID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let profiles = try MobileRemoteProfileStore(
            databaseURL: storageDirectory.appendingPathComponent("\(accountDigest).sqlite3"),
            account: account, vaultID: vaultID, key: vaultKey
        )
        let service = MobileRemoteSavedProfileService(
            profiles: profiles, secrets: secrets, account: account, vaultID: vaultID
        )
        cachedService = service
        return service
    }
}

/// UI-facing saved-profile vault boundary.
public protocol MobileRemoteSavedProfileServing: Sendable {
    /// Lists encrypted saved profiles without returning passwords.
    func profiles() async throws -> [MobileRemoteProfile]
    /// Saves one password-backed profile.
    func savePasswordProfile(_ profile: MobileRemoteProfile, password: String, interaction: MobileRemoteSecretInteraction) async throws -> MobileRemoteProfile
    /// Loads one profile and short-lived password material.
    func loadPasswordProfile(profileID: UUID, interaction: MobileRemoteSecretInteraction) async throws -> (profile: MobileRemoteProfile, credential: MobileRemoteCredentialMaterial)?
    /// Removes one profile and its exact secret item.
    func remove(profileID: UUID) async throws
}

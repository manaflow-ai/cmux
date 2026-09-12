#if DEBUG
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxNextTransport
import Foundation
import IrohLib
import Observation
import OSLog

extension MobileHostNextTransportRuntime {
    enum NextTransportIdentityStorageError: Error { case missingDeviceID, invalidLegacyKey }
    // MARK: - Key storage (Keychain; one-time migration from UserDefaults)

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadOrCreateIdentity() async throws -> PeerIdentity {
        let defaults = UserDefaults.standard
        if let key = try await loadOrMigrateSecret(
            account: identityKeyAccount, legacyDefaultsKey: legacyIdentityKeyDefaultsKey)
        {
            guard let deviceID = defaults.string(forKey: identityDeviceIDDefaultsKey) else {
                throw NextTransportIdentityStorageError.missingDeviceID
            }
            return try PeerIdentity(
                appIdentity: "dev.cmux.next.host", deviceID: deviceID, privateKeyData: key)
        }
        let fresh = PeerIdentity.generate(
            appIdentity: "dev.cmux.next.host",
            deviceID: defaults.string(forKey: identityDeviceIDDefaultsKey)
                ?? UUID().uuidString.lowercased())
        try await storeSecret(fresh.privateKeyData, account: identityKeyAccount)
        defaults.set(fresh.deviceID, forKey: identityDeviceIDDefaultsKey)
        MobileHostNextTransportRuntime.logger.notice(
            "host identity CREATED device=\(String(fresh.deviceID.prefix(8)), privacy: .public)")
        return fresh
    }

    /// The signer persists like the identity: a fresh key per launch would
    /// invalidate every previously minted phone grant on every Mac restart,
    /// forcing phones through re-credentialing.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadOrCreateSigner() async throws -> GrantSigner {
        if let key = try await loadOrMigrateSecret(
            account: signerKeyAccount, legacyDefaultsKey: legacySignerKeyDefaultsKey)
        {
            return try GrantSigner(privateKeyData: key)
        }
        let signer = GrantSigner()
        try await storeSecret(signer.privateKeyData, account: signerKeyAccount)
        MobileHostNextTransportRuntime.logger.notice(
            """
            host signer CREATED (fresh; any previously minted phone grants \
            are now invalid) \
            signerKey=\(HexEncoding().lowercase(signer.publicKeyData.prefix(4)), privacy: .public)
            """)
        return signer
    }

    /// Reads one private key from the Keychain, adopting a legacy
    /// UserDefaults copy exactly once (read old → write Keychain → delete
    /// old). Read or write errors propagate; only confirmed absence may
    /// cause callers to generate a new key.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadOrMigrateSecret(
        account: String, legacyDefaultsKey: String,
        store: any CmxIrohSecureIdentityStoring = CmxIrohKeychainIdentityStore(service: keyStoreService),
        defaults: UserDefaults = .standard
    ) async throws -> Data? {
        if let stored = try await store.read(account: account) { return stored }
        guard let legacyB64 = defaults.string(forKey: legacyDefaultsKey) else { return nil }
        guard let legacy = Data(base64Encoded: legacyB64), legacy.count == 32 else {
            throw NextTransportIdentityStorageError.invalidLegacyKey
        }
        try await store.write(legacy, account: account)
        defaults.removeObject(forKey: legacyDefaultsKey)
        return legacy
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func storeSecret(_ data: Data, account: String) async throws {
        try await CmxIrohKeychainIdentityStore(service: keyStoreService).write(data, account: account)
    }

    // MARK: - Relay credential cache (Keychain persistence)

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadCachedRelayCredentials()
        async -> [NextTransportCachedRelayCredential]
    {
        let store = CmxIrohKeychainCredentialStore(service: credentialCacheService)
        do {
            guard let data = try await store.read(account: credentialCacheAccount) else {
                return []
            }
            return NextTransportRelayCredentialCachePolicy().decode(data)
        } catch {
            MobileHostNextTransportRuntime.logger.error(
                """
                host relay credential cache read failed \
                error=\(String(describing: error), privacy: .public); starting uncached
                """)
            return []
        }
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func persistCachedRelayCredentials(
        _ entries: [NextTransportCachedRelayCredential]
    ) async {
        guard !entries.isEmpty,
            let data = NextTransportRelayCredentialCachePolicy().encode(entries)
        else { return }
        do {
            try await CmxIrohKeychainCredentialStore(service: credentialCacheService)
                .write(
                    data, account: credentialCacheAccount,
                    accessibility: .afterFirstUnlockThisDeviceOnly)
        } catch {
            MobileHostNextTransportRuntime.logger.error(
                """
                host relay credential cache write failed \
                error=\(String(describing: error), privacy: .public); next launch mints fresh
                """)
        }
    }

    // MARK: - Broker client

    /// Staging broker credentials from the dev dogfood env when present;
    /// nil (direct-only host) otherwise. Reads the same secrets file the
    /// dogfood tooling provisions — nonisolated, and constructed off the
    /// main actor by start(), because that read is file I/O.
    nonisolated static func brokerClient(identity: PeerIdentity) -> BrokerCredentialClient? {
        let env = ProcessInfo.processInfo.environment
        guard
            let email = env["CMUX_DOGFOOD_STACK_EMAIL"] ?? Self.secretsValue("CMUX_DOGFOOD_STACK_EMAIL"),
            let password = env["CMUX_DOGFOOD_STACK_PASSWORD"]
                ?? Self.secretsValue("CMUX_DOGFOOD_STACK_PASSWORD")
        else { return nil }
        return BrokerCredentialClient(
            environment: .staging,
            identity: identity,
            auth: .password(email: email, password: password),
            tag: "next-transport-host",
            platform: "mac")
    }

    private nonisolated static func secretsValue(_ key: String) -> String? {
        let path = ("~/.secrets/cmuxterm-dev.env" as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key)=") else { continue }
            return String(trimmed.dropFirst(key.count + 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}
#endif

import CryptoKit
public import CMUXMobileCore
public import Foundation

/// The Mac-local account, app, and namespace scope owning one allowlist store.
public struct CmxIrohPairedPeerAllowlistScope: Equatable, Sendable {
    public let accountID: String
    public let clientNamespace: String
    public let appInstanceID: String

    public init(
        accountID: String,
        clientNamespace: String,
        appInstanceID: String
    ) {
        self.accountID = accountID
        self.clientNamespace = clientNamespace
        self.appInstanceID = appInstanceID
    }
}

/// One phone endpoint whose pairing this Mac has already verified once.
///
/// The entry pins the complete initiator and acceptor tuples the verified pair
/// grant carried, so allowlist admission preserves exactly the account-scoped
/// binding authority the grant used to prove in-band. `expiresAt` is the
/// signed expiry of the last verified grant: allowlist authority never
/// outlives the credential that established it.
public struct CmxIrohPairedPeerAllowlistEntry: Equatable, Sendable {
    public let initiator: CmxIrohGrantPeer
    public let acceptor: CmxIrohGrantPeer
    public let expiresAt: Date
    public let recordedAt: Date

    public init(
        initiator: CmxIrohGrantPeer,
        acceptor: CmxIrohGrantPeer,
        expiresAt: Date,
        recordedAt: Date
    ) {
        self.initiator = initiator
        self.acceptor = acceptor
        self.expiresAt = expiresAt
        self.recordedAt = recordedAt
    }
}

/// Durable Mac-side allowlist of phone EndpointIDs whose pairing was verified.
///
/// Written once when a pair grant is verified for the first time for a given
/// phone endpoint; read on later connections to admit the TLS-proven remote
/// EndpointID with no in-band credential. Entries are evicted on local revoke,
/// on a definitive online registry denial, on acceptor identity change, and on
/// grant-expiry lapse. Storage follows the host-policy convention: one secure
/// record scoped to the active account, app instance, and bundle namespace.
public actor CmxIrohPairedPeerAllowlist {
    private static let storageAccount = "paired-peer-allowlist"

    /// Bounds the persisted record; oldest entries fall off first.
    public static let maximumEntryCount = 32

    private struct StoredPeer: Codable, Equatable {
        let bindingID: String
        let deviceID: String
        let tag: String
        let platform: String
        let endpointID: String
        let identityGeneration: Int

        init(_ peer: CmxIrohGrantPeer) {
            bindingID = peer.bindingID
            deviceID = peer.deviceID
            tag = peer.tag
            platform = peer.platform.rawValue
            endpointID = peer.endpointID.endpointID
            identityGeneration = peer.identityGeneration
        }

        func grantPeer() throws -> CmxIrohGrantPeer {
            guard let platform = CmxIrohPlatform(rawValue: platform) else {
                throw CancellationError()
            }
            return CmxIrohGrantPeer(
                bindingID: bindingID,
                deviceID: deviceID,
                tag: tag,
                platform: platform,
                endpointID: try CmxIrohPeerIdentity(endpointID: endpointID),
                identityGeneration: identityGeneration
            )
        }
    }

    private struct StoredEntry: Codable, Equatable {
        let initiator: StoredPeer
        let acceptor: StoredPeer
        let expiresAtSeconds: Int64
        let recordedAtSeconds: Int64
    }

    private struct StoredRecord: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let scopeDigest: String
        let entries: [StoredEntry]
    }

    private let secureStore: any CmxIrohSecureCredentialStoring
    private var loadedEntries: [StoredEntry]?
    private var loadedScopeDigest: String?
    private var deactivationCount = 0

    /// Creates an allowlist with injectable secure storage.
    ///
    /// The production default uses a Keychain service distinct from host
    /// policy and relay credentials, with device-only data protection.
    public init(
        secureStore: any CmxIrohSecureCredentialStoring = CmxIrohKeychainCredentialStore(
            service: "com.cmuxterm.iroh.paired-peers.v1"
        )
    ) {
        self.secureStore = secureStore
    }

    /// Records one verified pairing, replacing any prior entry for the same
    /// phone endpoint. A no-op when an identical entry is already stored.
    public func record(
        _ entry: CmxIrohPairedPeerAllowlistEntry,
        scope: CmxIrohPairedPeerAllowlistScope,
        now: Date
    ) async {
        guard deactivationCount == 0,
              entry.initiator.platform == .ios,
              entry.acceptor.platform == .mac,
              entry.expiresAt > now else { return }
        var entries = await entries(scope: scope)
        let stored = StoredEntry(
            initiator: StoredPeer(entry.initiator),
            acceptor: StoredPeer(entry.acceptor),
            expiresAtSeconds: Int64(entry.expiresAt.timeIntervalSince1970.rounded(.down)),
            recordedAtSeconds: Int64(entry.recordedAt.timeIntervalSince1970.rounded(.down))
        )
        if let existing = entries.first(where: {
            $0.initiator.endpointID == stored.initiator.endpointID
        }), existing == stored {
            return
        }
        entries.removeAll { $0.initiator.endpointID == stored.initiator.endpointID }
        entries.append(stored)
        if entries.count > Self.maximumEntryCount {
            entries.sort { $0.recordedAtSeconds < $1.recordedAtSeconds }
            entries.removeFirst(entries.count - Self.maximumEntryCount)
        }
        await persist(entries, scope: scope)
    }

    /// Returns the unexpired entry for one TLS-proven phone EndpointID, or
    /// `nil` when the endpoint was never paired under this scope. An expired
    /// entry is deleted and reported as a miss.
    public func entry(
        forInitiatorEndpointID endpointID: CmxIrohPeerIdentity,
        scope: CmxIrohPairedPeerAllowlistScope,
        now: Date
    ) async -> CmxIrohPairedPeerAllowlistEntry? {
        guard deactivationCount == 0 else { return nil }
        let entries = await entries(scope: scope)
        guard let stored = entries.first(where: {
            $0.initiator.endpointID == endpointID.endpointID
        }) else { return nil }
        let expiresAt = Date(timeIntervalSince1970: TimeInterval(stored.expiresAtSeconds))
        guard expiresAt > now,
              let initiator = try? stored.initiator.grantPeer(),
              let acceptor = try? stored.acceptor.grantPeer() else {
            await persist(
                entries.filter {
                    $0.initiator.endpointID != endpointID.endpointID
                },
                scope: scope
            )
            return nil
        }
        return CmxIrohPairedPeerAllowlistEntry(
            initiator: initiator,
            acceptor: acceptor,
            expiresAt: expiresAt,
            recordedAt: Date(
                timeIntervalSince1970: TimeInterval(stored.recordedAtSeconds)
            )
        )
    }

    /// Removes the entry for one phone endpoint after a definitive refusal.
    public func removeEntry(
        forInitiatorEndpointID endpointID: CmxIrohPeerIdentity,
        scope: CmxIrohPairedPeerAllowlistScope
    ) async {
        guard deactivationCount == 0 else { return }
        let entries = await entries(scope: scope)
        let retained = entries.filter {
            $0.initiator.endpointID != endpointID.endpointID
        }
        guard retained.count != entries.count else { return }
        await persist(retained, scope: scope)
    }

    /// Applies a local revoke: entries whose initiator carries the binding are
    /// removed, and a revoke of this Mac's own acceptor binding clears all.
    public func removeEntries(
        bindingID: String,
        scope: CmxIrohPairedPeerAllowlistScope
    ) async {
        guard deactivationCount == 0 else { return }
        let entries = await entries(scope: scope)
        let retained = entries.filter {
            $0.initiator.bindingID != bindingID && $0.acceptor.bindingID != bindingID
        }
        guard retained.count != entries.count else { return }
        await persist(retained, scope: scope)
    }

    /// Removes every entry during sign-out or app-instance revocation.
    public func deactivate() async throws {
        deactivationCount += 1
        defer { deactivationCount -= 1 }
        loadedEntries = nil
        loadedScopeDigest = nil
        try await secureStore.deleteAll()
    }

    private func entries(
        scope: CmxIrohPairedPeerAllowlistScope
    ) async -> [StoredEntry] {
        let digest = Self.scopeDigest(for: scope)
        if let loadedEntries, loadedScopeDigest == digest {
            return loadedEntries
        }
        let data = try? await secureStore.read(account: Self.storageAccount)
        guard let data,
              let record = try? JSONDecoder().decode(StoredRecord.self, from: data),
              record.version == StoredRecord.currentVersion,
              record.scopeDigest == digest else {
            // Wrong scope (account/app-instance transition) or corrupt data:
            // the prior owner's entries must not authorize this scope.
            loadedEntries = []
            loadedScopeDigest = digest
            if data != nil {
                try? await secureStore.delete(account: Self.storageAccount)
            }
            return []
        }
        loadedEntries = record.entries
        loadedScopeDigest = digest
        return record.entries
    }

    private func persist(
        _ entries: [StoredEntry],
        scope: CmxIrohPairedPeerAllowlistScope
    ) async {
        let digest = Self.scopeDigest(for: scope)
        loadedEntries = entries
        loadedScopeDigest = digest
        guard !entries.isEmpty else {
            try? await secureStore.delete(account: Self.storageAccount)
            return
        }
        let record = StoredRecord(
            version: StoredRecord.currentVersion,
            scopeDigest: digest,
            entries: entries
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? await secureStore.write(
            data,
            account: Self.storageAccount,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }

    private static func scopeDigest(
        for scope: CmxIrohPairedPeerAllowlistScope
    ) -> String {
        let transcript = Data(
            "cmux/iroh/paired-peer-allowlist-scope/v1\0\(scope.accountID)\0\(scope.clientNamespace)\0\(scope.appInstanceID)".utf8
        )
        return SHA256.hash(data: transcript)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

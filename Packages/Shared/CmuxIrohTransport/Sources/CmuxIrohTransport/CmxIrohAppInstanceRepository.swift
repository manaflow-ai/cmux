import CryptoKit
public import Foundation

/// Persists the broker-facing app-instance UUID for one active account and tag.
public actor CmxIrohAppInstanceRepository {
    private static let activeScopeKey = "cmux.iroh.app-instance.scope.v1"
    private static let identifierKey = "cmux.iroh.app-instance.id.v1"

    private let store: any CmxIrohInstallStateStoring
    private let makeUUID: @Sendable () -> UUID

    public init(
        store: any CmxIrohInstallStateStoring = CmxIrohUserDefaultsInstallStateStore(),
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.makeUUID = makeUUID
    }

    /// Returns a stable lowercase UUID and rotates it when account or tag changes.
    public func appInstanceID(accountID: String, tag: String) throws -> String {
        guard !accountID.isEmpty,
              accountID.utf8.count <= 1_024,
              Self.isSafeTag(tag) else {
            throw CmxIrohIdentityRepositoryError.invalidScope
        }
        let scope = Self.scope(accountID: accountID, tag: tag)
        if store.string(forKey: Self.activeScopeKey) == scope,
           let existing = store.string(forKey: Self.identifierKey),
           Self.isCanonicalUUID(existing) {
            return existing
        }
        let identifier = makeUUID().uuidString.lowercased()
        guard Self.isCanonicalUUID(identifier) else {
            throw CmxIrohIdentityRepositoryError.randomGenerationFailed(-1)
        }
        store.set(scope, forKey: Self.activeScopeKey)
        store.set(identifier, forKey: Self.identifierKey)
        return identifier
    }

    /// Removes the active app instance during sign-out or local revocation.
    public func deactivate() {
        store.set(nil, forKey: Self.activeScopeKey)
        store.set(nil, forKey: Self.identifierKey)
    }

    private static func scope(accountID: String, tag: String) -> String {
        let transcript = Data("cmux/iroh/app-instance-scope/v1\0\(accountID)\0\(tag)".utf8)
        return SHA256.hash(data: transcript).map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isSafeTag(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 58, 95].contains(byte)
        }
    }
}

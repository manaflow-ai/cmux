import CryptoKit
import Foundation

/// Durably queues binding revocations without retaining authentication tokens.
public actor CmxIrohPendingRevocationOutbox {
    private static let currentVersion = 1
    private static let maximumEntryCount = 16
    private static let maximumEncodedByteCount = 64 * 1_024

    private let secureStore: any CmxIrohSecureCredentialStoring
    private var busyScopes: Set<String> = []
    private var scopeWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Creates an outbox backed by injected device-only secure storage.
    ///
    /// Production callers should inject a dedicated ``CmxIrohKeychainCredentialStore``
    /// service. Tests can inject an in-memory store without touching user state.
    ///
    /// - Parameter secureStore: Storage used only for pending revocation records.
    public init(secureStore: any CmxIrohSecureCredentialStoring) {
        self.secureStore = secureStore
    }

    /// Idempotently persists a binding before local identity state is removed.
    ///
    /// - Parameter revocation: The account-and-tag-scoped binding to revoke.
    /// - Throws: A validation, capacity, encoding, or secure-storage error.
    public func enqueue(_ revocation: CmxIrohPendingRevocation) async throws {
        let scope = Self.scope(revocation.accountID)
        await acquire(scope: scope)
        defer { release(scope: scope) }
        var entries = try await load(accountID: revocation.accountID)
        if let existing = entries.first(where: {
            $0.bindingID == revocation.bindingID
        }) {
            guard existing == revocation else {
                throw CmxIrohPendingRevocationError.invalidStoredState
            }
            return
        }
        guard entries.count < Self.maximumEntryCount else {
            throw CmxIrohPendingRevocationError.capacityExceeded
        }
        entries.append(revocation)
        try await persist(entries, accountID: revocation.accountID)
    }

    /// Loads validated pending records for one exact authenticated account.
    ///
    /// - Parameter accountID: The account whose opaque Keychain scope is read.
    /// - Returns: The insertion-ordered pending records for that account.
    /// - Throws: A validation, decoding, or secure-storage error.
    public func pending(accountID: String) async throws -> [CmxIrohPendingRevocation] {
        guard CmxIrohPendingRevocation.isSafeAccountID(accountID) else {
            throw CmxIrohPendingRevocationError.invalidRecord
        }
        let scope = Self.scope(accountID)
        await acquire(scope: scope)
        defer { release(scope: scope) }
        return try await load(accountID: accountID)
    }

    /// Revokes every pending binding owned by an account before registration.
    ///
    /// The current tag is attempted first, followed by older build tags. A
    /// broker or persistence failure leaves the unconfirmed record durable and
    /// stops the drain, so callers must not register or discover afterward.
    ///
    /// - Parameters:
    ///   - accountID: The currently authenticated account.
    ///   - tag: The build tag about to register.
    ///   - broker: An authenticated idempotent binding revoker.
    /// - Throws: The first broker, validation, decoding, or persistence error.
    public func revokePending(
        accountID: String,
        beforeRegisteringTag tag: String,
        using broker: any CmxIrohBindingRevoking
    ) async throws {
        guard CmxIrohPendingRevocation.isSafeAccountID(accountID),
              CmxIrohPendingRevocation.isSafeTag(tag) else {
            throw CmxIrohPendingRevocationError.invalidRecord
        }
        let snapshot = try await pending(accountID: accountID)
        let ordered = snapshot.filter { $0.tag == tag }
            + snapshot.filter { $0.tag != tag }
        for revocation in ordered {
            try await broker.revoke(bindingID: revocation.bindingID)

            try await removeConfirmed(revocation)
        }
    }

    private func removeConfirmed(
        _ revocation: CmxIrohPendingRevocation
    ) async throws {
        let scope = Self.scope(revocation.accountID)
        await acquire(scope: scope)
        defer { release(scope: scope) }

        // The broker call is an actor reentrancy point. Reload before the
        // compare-remove so a concurrent enqueue cannot be overwritten.
        var current = try await load(accountID: revocation.accountID)
        current.removeAll { $0 == revocation }
        try await persist(current, accountID: revocation.accountID)
    }

    private func load(accountID: String) async throws -> [CmxIrohPendingRevocation] {
        guard CmxIrohPendingRevocation.isSafeAccountID(accountID) else {
            throw CmxIrohPendingRevocationError.invalidRecord
        }
        guard let data = try await secureStore.read(account: Self.scope(accountID)) else {
            return []
        }
        guard data.count <= Self.maximumEncodedByteCount,
              let stored = try? JSONDecoder().decode(
                  CmxIrohStoredPendingRevocations.self,
                  from: data
              ),
              stored.version == Self.currentVersion,
              stored.entries.count <= Self.maximumEntryCount,
              stored.entries.allSatisfy({ $0.accountID == accountID }),
              Set(stored.entries.map(\.bindingID)).count == stored.entries.count else {
            throw CmxIrohPendingRevocationError.invalidStoredState
        }
        return stored.entries
    }

    private func persist(
        _ entries: [CmxIrohPendingRevocation],
        accountID: String
    ) async throws {
        let scope = Self.scope(accountID)
        guard !entries.isEmpty else {
            try await secureStore.delete(account: scope)
            return
        }
        guard entries.count <= Self.maximumEntryCount,
              entries.allSatisfy({ $0.accountID == accountID }),
              Set(entries.map(\.bindingID)).count == entries.count else {
            throw CmxIrohPendingRevocationError.invalidStoredState
        }
        let data = try JSONEncoder().encode(
            CmxIrohStoredPendingRevocations(
                version: Self.currentVersion,
                entries: entries
            )
        )
        guard data.count <= Self.maximumEncodedByteCount else {
            throw CmxIrohPendingRevocationError.capacityExceeded
        }
        try await secureStore.write(
            data,
            account: scope,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }

    private static func scope(_ accountID: String) -> String {
        let transcript = Data(
            "cmux/iroh/pending-revocations/v1\0\(accountID)".utf8
        )
        return SHA256.hash(data: transcript)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func acquire(scope: String) async {
        guard busyScopes.contains(scope) else {
            busyScopes.insert(scope)
            return
        }
        await withCheckedContinuation { continuation in
            scopeWaiters[scope, default: []].append(continuation)
        }
    }

    private func release(scope: String) {
        guard var waiters = scopeWaiters[scope], !waiters.isEmpty else {
            busyScopes.remove(scope)
            scopeWaiters.removeValue(forKey: scope)
            return
        }
        let next = waiters.removeFirst()
        if waiters.isEmpty {
            scopeWaiters.removeValue(forKey: scope)
        } else {
            scopeWaiters[scope] = waiters
        }
        next.resume()
    }
}

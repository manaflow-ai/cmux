public import Foundation

/// Device-local secure storage for user-provided custom relay tokens.
public actor CmxIrohCustomRelayCredentialStore {
    private struct Record: Codable {
        let version: Int
        var staticTokens: [String: String]
    }

    private static let recordVersion = 1
    private let secureStore: any CmxIrohSecureCredentialStoring
    private var busyAccounts: Set<String> = []
    private var accountWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Creates an account-scoped custom relay credential repository.
    public init(
        secureStore: any CmxIrohSecureCredentialStoring = CmxIrohKeychainCredentialStore(
            service: "com.cmuxterm.iroh.custom-relay-credentials.v1"
        )
    ) {
        self.secureStore = secureStore
    }

    /// Saves or replaces one static relay token for the authenticated account.
    public func setStaticToken(
        _ token: String,
        relayID: String,
        accountID: String
    ) async throws {
        guard CmxIrohRelayStorageScope.isSafeRelayID(relayID),
              CmxIrohRelayStorageScope.isSafeToken(token) else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        let account = try CmxIrohRelayStorageScope.account(
            accountID,
            prefix: "custom-relay-credentials"
        )
        await acquire(account)
        defer { release(account) }
        var tokens = try await storedTokens(account: account)
        tokens[relayID] = token
        try await write(tokens, account: account)
    }

    /// Removes one device-local relay token without changing the account preference.
    public func removeCredential(relayID: String, accountID: String) async throws {
        guard CmxIrohRelayStorageScope.isSafeRelayID(relayID) else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        let account = try CmxIrohRelayStorageScope.account(
            accountID,
            prefix: "custom-relay-credentials"
        )
        await acquire(account)
        defer { release(account) }
        var tokens = try await storedTokens(account: account)
        tokens.removeValue(forKey: relayID)
        if tokens.isEmpty {
            try await secureStore.delete(account: account)
        } else {
            try await write(tokens, account: account)
        }
    }

    /// Removes every custom relay token for one authenticated account.
    public func deactivate(accountID: String) async throws {
        let account = try CmxIrohRelayStorageScope.account(
            accountID,
            prefix: "custom-relay-credentials"
        )
        await acquire(account)
        defer { release(account) }
        try await secureStore.delete(account: account)
    }

    func staticTokens(accountID: String) async throws -> [String: String] {
        let account = try CmxIrohRelayStorageScope.account(
            accountID,
            prefix: "custom-relay-credentials"
        )
        await acquire(account)
        defer { release(account) }
        return try await storedTokens(account: account)
    }

    private func acquire(_ account: String) async {
        guard busyAccounts.contains(account) else {
            busyAccounts.insert(account)
            return
        }
        await withCheckedContinuation { continuation in
            accountWaiters[account, default: []].append(continuation)
        }
    }

    private func release(_ account: String) {
        guard var waiters = accountWaiters[account], !waiters.isEmpty else {
            busyAccounts.remove(account)
            accountWaiters.removeValue(forKey: account)
            return
        }
        let next = waiters.removeFirst()
        if waiters.isEmpty {
            accountWaiters.removeValue(forKey: account)
        } else {
            accountWaiters[account] = waiters
        }
        next.resume()
    }

    private func storedTokens(account: String) async throws -> [String: String] {
        guard let data = try await secureStore.read(account: account) else { return [:] }
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == Self.recordVersion,
              record.staticTokens.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount,
              record.staticTokens.allSatisfy({
                  CmxIrohRelayStorageScope.isSafeRelayID($0.key)
                      && CmxIrohRelayStorageScope.isSafeToken($0.value)
              }) else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        return record.staticTokens
    }

    private func write(_ tokens: [String: String], account: String) async throws {
        guard tokens.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount else {
            throw CmxIrohRelayPolicyError.invalidSelection
        }
        try await secureStore.write(
            JSONEncoder().encode(Record(version: Self.recordVersion, staticTokens: tokens)),
            account: account,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }
}

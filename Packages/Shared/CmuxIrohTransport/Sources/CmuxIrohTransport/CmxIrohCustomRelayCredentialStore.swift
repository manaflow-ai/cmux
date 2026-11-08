public import Foundation

/// Device-local secure storage for user-provided custom relay tokens.
public actor CmxIrohCustomRelayCredentialStore {
    private struct StaticCredential: Codable, Equatable {
        let token: String
        let relayURL: String
    }

    private struct Record: Codable {
        let version: Int
        var staticCredentials: [String: StaticCredential]
    }

    private struct LegacyRecord: Codable {
        let version: Int
        let staticTokens: [String: String]
    }

    private static let recordVersion = 2
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
        relayURL: String,
        accountID: String
    ) async throws {
        guard CmxIrohRelayStorageScope.isSafeRelayID(relayID),
              CmxIrohRelayStorageScope.isSafeToken(token),
              (try? CmxIrohCustomRelay(url: relayURL)) != nil else {
            throw CmxIrohRelayPolicyError.invalidClaims
        }
        let account = try CmxIrohRelayStorageScope.account(
            accountID,
            prefix: "custom-relay-credentials"
        )
        await acquire(account)
        defer { release(account) }
        var credentials = try await storedCredentials(account: account)
        credentials[relayID] = StaticCredential(token: token, relayURL: relayURL)
        try await write(credentials, account: account)
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
        var credentials = try await storedCredentials(account: account)
        credentials.removeValue(forKey: relayID)
        if credentials.isEmpty {
            try await secureStore.delete(account: account)
        } else {
            try await write(credentials, account: account)
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

    /// Deletes tokens that no longer correspond to saved secret-bearing relays.
    /// Calling this after every authoritative account update also retries cleanup
    /// after a previous transient Keychain failure.
    public func retainCredentials(
        for relays: [CmxIrohCustomRelayDefinition],
        accountID: String
    ) async throws {
        guard relays.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount,
              Set(relays.map(\.id)).count == relays.count else {
            throw CmxIrohRelayPolicyError.invalidSelection
        }
        let account = try CmxIrohRelayStorageScope.account(
            accountID,
            prefix: "custom-relay-credentials"
        )
        await acquire(account)
        defer { release(account) }
        let credentials = try await storedCredentials(account: account)
        let definitions = Dictionary(uniqueKeysWithValues: relays.map { ($0.id, $0) })
        let retained = credentials.filter { id, credential in
            guard let relay = definitions[id] else { return false }
            return relay.authMode == .staticToken && relay.url == credential.relayURL
        }
        guard retained != credentials else { return }
        if retained.isEmpty {
            try await secureStore.delete(account: account)
        } else {
            try await write(retained, account: account)
        }
    }

    func staticTokens(
        for relays: [CmxIrohCustomRelayDefinition],
        accountID: String
    ) async throws -> [String: String] {
        guard relays.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount,
              Set(relays.map(\.id)).count == relays.count else {
            throw CmxIrohRelayPolicyError.invalidSelection
        }
        let account = try CmxIrohRelayStorageScope.account(
            accountID,
            prefix: "custom-relay-credentials"
        )
        await acquire(account)
        defer { release(account) }
        let credentials = try await storedCredentials(account: account)
        var tokens: [String: String] = [:]
        for relay in relays where relay.authMode == .staticToken {
            guard let credential = credentials[relay.id],
                  credential.relayURL == relay.url else { continue }
            tokens[relay.id] = credential.token
        }
        return tokens
    }

    func configuredRelayIDs(accountID: String) async throws -> Set<String> {
        let account = try CmxIrohRelayStorageScope.account(
            accountID,
            prefix: "custom-relay-credentials"
        )
        await acquire(account)
        defer { release(account) }
        return Set(try await storedCredentials(account: account).keys)
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

    private func storedCredentials(account: String) async throws -> [String: StaticCredential] {
        guard let data = try await secureStore.read(account: account) else { return [:] }
        if let record = try? JSONDecoder().decode(Record.self, from: data),
           record.version == Self.recordVersion,
           record.staticCredentials.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount,
           record.staticCredentials.allSatisfy({ id, credential in
               CmxIrohRelayStorageScope.isSafeRelayID(id)
                   && CmxIrohRelayStorageScope.isSafeToken(credential.token)
                   && (try? CmxIrohCustomRelay(url: credential.relayURL)) != nil
           }) {
            return record.staticCredentials
        }
        if let legacy = try? JSONDecoder().decode(LegacyRecord.self, from: data),
           legacy.version == 1 {
            try await secureStore.delete(account: account)
            return [:]
        }
        throw CmxIrohRelayPolicyError.invalidClaims
    }

    private func write(
        _ credentials: [String: StaticCredential],
        account: String
    ) async throws {
        guard credentials.count <= CmxIrohRelayPolicyVerifier.maximumRelayCount else {
            throw CmxIrohRelayPolicyError.invalidSelection
        }
        try await secureStore.write(
            JSONEncoder().encode(
                Record(version: Self.recordVersion, staticCredentials: credentials)
            ),
            account: account,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }
}

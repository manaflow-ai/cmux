import CryptoKit
public import Foundation

/// Persists one active account's broker binding and relay capability.
public actor CmxIrohBrokerCredentialRepository {
    private static let activeScopeKey = "cmux.iroh.broker-credentials.scope.v1"
    private static let bindingKey = "cmux.iroh.broker-credentials.binding.v1"

    private let secureStore: any CmxIrohSecureCredentialStoring
    private let installState: any CmxIrohInstallStateStoring
    private var lifecycleEpoch: UInt64 = 0
    private var deactivationCount = 0
    private var activeStorageMutationCount = 0
    private var storageMutationDrainWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a broker credential repository with injectable persistence.
    ///
    /// - Parameters:
    ///   - secureStore: Device-only Keychain storage for relay capabilities.
    ///   - installState: Non-secret defaults storage for the active binding tuple.
    public init(
        secureStore: any CmxIrohSecureCredentialStoring = CmxIrohKeychainCredentialStore(),
        installState: any CmxIrohInstallStateStoring = CmxIrohUserDefaultsInstallStateStore()
    ) {
        self.secureStore = secureStore
        self.installState = installState
    }

    /// Loads binding metadata for one exact account and app instance.
    ///
    /// Activating a different scope first removes all state from the prior
    /// account or app instance so returning to it cannot resurrect credentials.
    ///
    /// - Parameters:
    ///   - accountID: The authenticated account identifier.
    ///   - appInstanceID: The installation's lowercase app-instance UUID.
    /// - Returns: The active binding metadata, or `nil` when registration is required.
    /// - Throws: A scope-validation or secure-storage error.
    public func loadBinding(
        accountID: String,
        appInstanceID: String
    ) async throws -> CmxIrohBrokerBindingMetadata? {
        let epoch = try beginOperation()
        let scope = try await prepareScope(
            accountID: accountID,
            appInstanceID: appInstanceID,
            epoch: epoch
        )
        return try await loadBinding(
            scope: scope,
            appInstanceID: appInstanceID,
            epoch: epoch
        )
    }

    /// Saves an exact broker binding, invalidating relay credentials if it changed.
    ///
    /// - Parameters:
    ///   - binding: The binding tuple returned by registration or discovery.
    ///   - accountID: The authenticated account identifier.
    /// - Throws: A scope-validation, encoding, or secure-storage error.
    public func saveBinding(
        _ binding: CmxIrohBrokerBindingMetadata,
        accountID: String
    ) async throws {
        let epoch = try beginOperation()
        let scope = try await prepareScope(
            accountID: accountID,
            appInstanceID: binding.appInstanceID,
            epoch: epoch
        )
        let existing = try await loadBinding(
            scope: scope,
            appInstanceID: binding.appInstanceID,
            epoch: epoch
        )
        if existing != binding {
            try await deleteSecureRecord(account: scope, epoch: epoch)
        }
        let encoded = try JSONEncoder().encode(binding)
        try requireCurrent(epoch)
        installState.set(String(decoding: encoded, as: UTF8.self), forKey: Self.bindingKey)
    }

    /// Loads a fresh relay credential for one exact binding and managed fleet.
    ///
    /// Stale, corrupt, wrong-binding, and wrong-fleet capabilities are deleted
    /// and returned as a cache miss.
    ///
    /// - Parameters:
    ///   - accountID: The authenticated account identifier.
    ///   - binding: The exact active binding tuple.
    ///   - expectedRelayFleet: The complete configured managed relay fleet.
    ///   - now: The validation time.
    /// - Returns: A validated relay credential, or `nil` when a new mint is required.
    /// - Throws: A scope-validation or secure-storage error.
    public func loadRelayCredential(
        accountID: String,
        binding: CmxIrohBrokerBindingMetadata,
        expectedRelayFleet: Set<String>,
        now: Date
    ) async throws -> CmxIrohRelayTokenResponse? {
        let epoch = try beginOperation()
        let scope = try await prepareScope(
            accountID: accountID,
            appInstanceID: binding.appInstanceID,
            epoch: epoch
        )
        guard try await loadBinding(
            scope: scope,
            appInstanceID: binding.appInstanceID,
            epoch: epoch
        ) == binding else {
            try await deleteSecureRecord(account: scope, epoch: epoch)
            return nil
        }
        guard let data = try await readSecureRecord(account: scope, epoch: epoch),
              let stored = try? JSONDecoder().decode(
                  CmxIrohStoredRelayCredential.self,
                  from: data
              ),
              stored.version == CmxIrohStoredRelayCredential.currentVersion,
              stored.binding == binding,
              hasExactFleet(stored.response.relayFleet, expected: expectedRelayFleet),
              (try? stored.response.relayConfigurations(now: now))?.count
                  == expectedRelayFleet.count else {
            try await deleteSecureRecord(account: scope, epoch: epoch)
            return nil
        }
        try requireCurrent(epoch)
        return stored.response
    }

    /// Saves a fresh relay credential for one exact binding and managed fleet.
    ///
    /// - Parameters:
    ///   - response: The relay token response returned by the trust broker.
    ///   - accountID: The authenticated account identifier.
    ///   - binding: The exact active binding tuple.
    ///   - expectedRelayFleet: The complete configured managed relay fleet.
    ///   - now: The validation time.
    /// - Throws: A validation, encoding, or secure-storage error.
    public func saveRelayCredential(
        _ response: CmxIrohRelayTokenResponse,
        accountID: String,
        binding: CmxIrohBrokerBindingMetadata,
        expectedRelayFleet: Set<String>,
        now: Date
    ) async throws {
        let epoch = try beginOperation()
        let scope = try await prepareScope(
            accountID: accountID,
            appInstanceID: binding.appInstanceID,
            epoch: epoch
        )
        guard let storedBinding = try await loadBinding(
            scope: scope,
            appInstanceID: binding.appInstanceID,
            epoch: epoch
        ) else {
            throw CmxIrohBrokerCredentialRepositoryError.bindingNotStored
        }
        guard storedBinding == binding else {
            try await deleteSecureRecord(account: scope, epoch: epoch)
            throw CmxIrohBrokerCredentialRepositoryError.bindingMismatch
        }
        guard hasExactFleet(response.relayFleet, expected: expectedRelayFleet) else {
            throw CmxIrohBrokerCredentialRepositoryError.relayFleetMismatch
        }
        guard (try? response.relayConfigurations(now: now))?.count
            == expectedRelayFleet.count else {
            throw CmxIrohBrokerCredentialRepositoryError.invalidRelayCredential
        }
        let record = CmxIrohStoredRelayCredential(binding: binding, response: response)
        try await writeSecureRecord(
            JSONEncoder().encode(record),
            account: scope,
            accessibility: .afterFirstUnlockThisDeviceOnly,
            epoch: epoch
        )
    }

    /// Removes a relay credential while preserving its broker binding.
    ///
    /// - Parameters:
    ///   - accountID: The authenticated account identifier.
    ///   - appInstanceID: The installation's lowercase app-instance UUID.
    /// - Throws: A scope-validation or secure-storage error.
    public func deleteRelayCredential(
        accountID: String,
        appInstanceID: String
    ) async throws {
        let epoch = try beginOperation()
        let scope = try await prepareScope(
            accountID: accountID,
            appInstanceID: appInstanceID,
            epoch: epoch
        )
        try await deleteSecureRecord(account: scope, epoch: epoch)
    }

    /// Removes a broker binding and every capability scoped to it.
    ///
    /// - Parameters:
    ///   - accountID: The authenticated account identifier.
    ///   - appInstanceID: The installation's lowercase app-instance UUID.
    /// - Throws: A scope-validation or secure-storage error.
    public func deleteBinding(
        accountID: String,
        appInstanceID: String
    ) async throws {
        let epoch = try beginOperation()
        let scope = try await prepareScope(
            accountID: accountID,
            appInstanceID: appInstanceID,
            epoch: epoch
        )
        try await deleteSecureRecord(account: scope, epoch: epoch)
        try requireCurrent(epoch)
        installState.set(nil, forKey: Self.bindingKey)
    }

    /// Removes all broker state during sign-out or local app-instance revocation.
    ///
    /// - Throws: A secure-storage error.
    public func deactivate() async throws {
        lifecycleEpoch &+= 1
        deactivationCount += 1
        defer { deactivationCount -= 1 }
        await waitForStorageMutations()
        try await secureStore.deleteAll()
        installState.set(nil, forKey: Self.bindingKey)
        installState.set(nil, forKey: Self.activeScopeKey)
    }

    private func prepareScope(
        accountID: String,
        appInstanceID: String,
        epoch: UInt64
    ) async throws -> String {
        try requireCurrent(epoch)
        guard !accountID.isEmpty,
              accountID.utf8.count <= 1_024,
              Self.isCanonicalUUID(appInstanceID) else {
            throw CmxIrohBrokerCredentialRepositoryError.invalidScope
        }
        let scope = Self.scope(accountID: accountID, appInstanceID: appInstanceID)
        guard installState.string(forKey: Self.activeScopeKey) != scope else {
            return scope
        }
        try await deleteAllSecureRecords(epoch: epoch)
        try requireCurrent(epoch)
        installState.set(nil, forKey: Self.bindingKey)
        installState.set(scope, forKey: Self.activeScopeKey)
        return scope
    }

    private func loadBinding(
        scope: String,
        appInstanceID: String,
        epoch: UInt64
    ) async throws -> CmxIrohBrokerBindingMetadata? {
        try requireCurrent(epoch)
        guard let encoded = installState.string(forKey: Self.bindingKey) else {
            return nil
        }
        guard let binding = try? JSONDecoder().decode(
            CmxIrohBrokerBindingMetadata.self,
            from: Data(encoded.utf8)
        ), binding.appInstanceID == appInstanceID else {
            installState.set(nil, forKey: Self.bindingKey)
            try await deleteSecureRecord(account: scope, epoch: epoch)
            return nil
        }
        try requireCurrent(epoch)
        return binding
    }

    private func beginOperation() throws -> UInt64 {
        guard deactivationCount == 0 else { throw CancellationError() }
        return lifecycleEpoch
    }

    private func requireCurrent(_ epoch: UInt64) throws {
        guard deactivationCount == 0,
              lifecycleEpoch == epoch else { throw CancellationError() }
    }

    private func readSecureRecord(
        account: String,
        epoch: UInt64
    ) async throws -> Data? {
        try requireCurrent(epoch)
        let data = try await secureStore.read(account: account)
        try requireCurrent(epoch)
        return data
    }

    private func writeSecureRecord(
        _ data: Data,
        account: String,
        accessibility: CmxIrohSecureCredentialAccessibility,
        epoch: UInt64
    ) async throws {
        try requireCurrent(epoch)
        activeStorageMutationCount += 1
        defer { finishStorageMutation() }
        try await secureStore.write(
            data,
            account: account,
            accessibility: accessibility
        )
        try requireCurrent(epoch)
    }

    private func deleteSecureRecord(
        account: String,
        epoch: UInt64
    ) async throws {
        try requireCurrent(epoch)
        activeStorageMutationCount += 1
        defer { finishStorageMutation() }
        try await secureStore.delete(account: account)
        try requireCurrent(epoch)
    }

    private func deleteAllSecureRecords(epoch: UInt64) async throws {
        try requireCurrent(epoch)
        activeStorageMutationCount += 1
        defer { finishStorageMutation() }
        try await secureStore.deleteAll()
        try requireCurrent(epoch)
    }

    private func finishStorageMutation() {
        activeStorageMutationCount -= 1
        guard activeStorageMutationCount == 0 else { return }
        let waiters = storageMutationDrainWaiters
        storageMutationDrainWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func waitForStorageMutations() async {
        guard activeStorageMutationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            storageMutationDrainWaiters.append(continuation)
        }
    }

    private func hasExactFleet(_ fleet: [String], expected: Set<String>) -> Bool {
        (1 ... CmxIrohRelayPolicyVerifier.maximumRelayCount).contains(expected.count)
            && fleet.count == expected.count
            && Set(fleet) == expected
    }

    private static func scope(accountID: String, appInstanceID: String) -> String {
        let transcript = Data(
            "cmux/iroh/broker-credential-scope/v1\0\(accountID)\0\(appInstanceID)".utf8
        )
        return SHA256.hash(data: transcript).map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}

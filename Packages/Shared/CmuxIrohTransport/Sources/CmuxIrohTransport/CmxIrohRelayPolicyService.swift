public import CMUXMobileCore
public import Foundation

/// Resolves signed managed policy, account preference, and device-only credentials.
public actor CmxIrohRelayPolicyService {
    private typealias Resolution = CmxIrohRelayPolicyResolutionResult
    private typealias Resolver = CmxIrohRelayPolicyResolution

    /// Bounded fail-open window in which ``restore`` keeps a recently-expired
    /// last-good managed policy dialable after a failed refresh (cmux#10375).
    /// A failed policy refresh must degrade to the last verified catalog, not
    /// to a zero-route profile; the relay itself remains the authority on
    /// credential validity and rejects a truly stale token.
    public static let defaultExpiredPolicyReuseGrace: TimeInterval = 6 * 60 * 60

    private let policyCache: CmxIrohRelayPolicyCache
    private let preferenceStore: CmxIrohRelayPreferenceStore
    private let credentialStore: CmxIrohCustomRelayCredentialStore
    private let broker: (any CmxIrohRelayPolicyServing)?
    private let expiredPolicyReuseGrace: TimeInterval
    private var currentEffective: CmxIrohEffectiveRelayPolicy?
    private var currentDiagnostics = CmxIrohRelayDiagnosticsSnapshot.inactive
    private var continuations: [UUID: AsyncStream<CmxIrohRelayDiagnosticsSnapshot>.Continuation] = [:]
    private var operationRevision: UInt64 = 0

    /// Creates an inactive relay policy service with injected persistence boundaries.
    public init(
        policyCache: CmxIrohRelayPolicyCache = CmxIrohRelayPolicyCache(),
        preferenceStore: CmxIrohRelayPreferenceStore = CmxIrohRelayPreferenceStore(),
        credentialStore: CmxIrohCustomRelayCredentialStore = CmxIrohCustomRelayCredentialStore(),
        broker: (any CmxIrohRelayPolicyServing)? = nil,
        expiredPolicyReuseGrace: TimeInterval = CmxIrohRelayPolicyService
            .defaultExpiredPolicyReuseGrace
    ) {
        self.policyCache = policyCache
        self.preferenceStore = preferenceStore
        self.credentialStore = credentialStore
        self.broker = broker
        self.expiredPolicyReuseGrace = max(0, expiredPolicyReuseGrace)
    }

    /// Fetches and installs the broker's current signed relay policy.
    @discardableResult
    public func refresh(
        accountID: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date = Date()
    ) async throws -> CmxIrohEffectiveRelayPolicy {
        guard let broker else { throw CmxIrohRelayPolicyServiceError.brokerUnavailable }
        let response = try await broker.fetchRelayPolicy()
        return try await install(
            response: response,
            accountID: accountID,
            trustRoot: trustRoot,
            now: now
        )
    }

    /// Verifies and resolves one broker response without replacing last-known-good
    /// runtime state when signature, expiry, rollback, or persistence checks fail.
    @discardableResult
    public func install(
        response: CmxIrohRelayPolicyResponse,
        accountID: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date = Date()
    ) async throws -> CmxIrohEffectiveRelayPolicy {
        let operation = beginOperation()
        do {
            try await Resolver.validatePreferenceRevision(
                response.preferenceRevision,
                configuration: response.preference,
                accountID: accountID,
                currentEffective: currentEffective,
                preferenceStore: preferenceStore
            )
            let policy = try await policyCache.install(
                signedPolicy: response.policy,
                trustRoot: trustRoot,
                now: now
            )
            let resolution = await Resolver.resolve(
                configuration: response.preference,
                revision: response.preferenceRevision,
                policy: policy,
                accountID: accountID,
                credentialStore: credentialStore,
                usedCachedPolicy: false,
                now: now
            )
            _ = try await preferenceStore.install(
                requested: response.preference,
                effective: resolution.effective.effectivePreference,
                revision: response.preferenceRevision,
                effectivePolicySequence: resolution.effective.managedPolicy?.sequence,
                staleRelayIDs: resolution.effective.staleRelayIDs,
                accountID: accountID
            )
            let cleanupFailure = await Resolver.cleanupOrphanCredentials(
                configuration: response.preference,
                accountID: accountID,
                credentialStore: credentialStore
            )
            try requireCurrent(operation)
            publish(
                resolution.effective,
                failure: cleanupFailure ?? resolution.failure
            )
            return resolution.effective
        } catch {
            if isCurrent(operation) {
                publishFailure(Resolver.failure(for: error))
            }
            throw error
        }
    }

    /// Restores the last-known-good signed policy and account preference.
    @discardableResult
    public func restore(
        accountID: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date = Date()
    ) async -> CmxIrohEffectiveRelayPolicy {
        let operation = beginOperation()
        let persisted: CmxIrohPersistedRelayPreference
        do {
            guard let stored = try await preferenceStore.load(accountID: accountID) else {
                return publishUnavailable(
                    configuration: nil,
                    revision: nil,
                    source: .managedUnavailable,
                    operation: operation,
                    failure: .policyUnavailable
                )
            }
            persisted = stored
        } catch {
            return publishUnavailable(
                configuration: nil,
                revision: nil,
                source: .managedUnavailable,
                operation: operation,
                failure: .policyUnavailable
            )
        }

        let cleanupFailure = await Resolver.cleanupOrphanCredentials(
            configuration: persisted.requested,
            accountID: accountID,
            credentialStore: credentialStore
        )
        if persisted.requested.mode == .custom {
            let policy = try? await policyCache.load(trustRoot: trustRoot, now: now)
            let resolution = await Resolver.resolve(
                configuration: persisted.requested,
                revision: persisted.revision,
                policy: policy,
                accountID: accountID,
                credentialStore: credentialStore,
                usedCachedPolicy: policy != nil,
                now: now
            )
            return commit(
                Resolution(
                    effective: resolution.effective,
                    failure: cleanupFailure ?? resolution.failure
                ),
                operation: operation
            )
        }

        do {
            // Restore is the failed-refresh fallback path, so it alone grants
            // the bounded expired-policy grace: a recently-expired last-good
            // catalog must stay dialable instead of zeroing every relay route
            // (cmux#10375). The graced state is visible as `.policyExpired`.
            guard let policy = try await policyCache.load(
                trustRoot: trustRoot,
                now: now,
                expiredPolicyReuseGrace: expiredPolicyReuseGrace
            ) else {
                return publishUnavailable(
                    configuration: persisted.requested,
                    revision: persisted.revision,
                    source: .managedUnavailable,
                    operation: operation,
                    failure: .policyUnavailable
                )
            }
            let policyIsExpired = TimeInterval(policy.expiresAt)
                <= now.timeIntervalSince1970
            let resolution = await Resolver.resolve(
                configuration: persisted.requested,
                revision: persisted.revision,
                policy: policy,
                accountID: accountID,
                credentialStore: credentialStore,
                usedCachedPolicy: true,
                now: now
            )
            return commit(
                Resolution(
                    effective: resolution.effective,
                    failure: policyIsExpired
                        ? .policyExpired
                        : cleanupFailure ?? resolution.failure
                ),
                operation: operation
            )
        } catch let error as CmxIrohRelayPolicyError where error == .expired {
            return publishUnavailable(
                configuration: persisted.requested,
                revision: persisted.revision,
                source: .managedUnavailable,
                operation: operation,
                failure: .policyExpired
            )
        } catch {
            return publishUnavailable(
                configuration: persisted.requested,
                revision: persisted.revision,
                source: .managedUnavailable,
                operation: operation,
                failure: Resolver.failure(for: error)
            )
        }
    }

    /// Updates only the active preference while retaining dormant account fields.
    @discardableResult
    public func setPreference(
        _ preference: CmxIrohAccountRelayPreference,
        accountID: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date = Date()
    ) async throws -> CmxIrohEffectiveRelayPolicy {
        let current: CmxIrohAccountRelayConfiguration
        if let live = currentEffective?.requestedConfiguration {
            current = live
        } else {
            current = try await preferenceStore.load(accountID: accountID)?.requested
                ?? .automatic
        }
        return try await setConfiguration(
            current.updatingActivePreference(preference),
            accountID: accountID,
            trustRoot: trustRoot,
            now: now
        )
    }

    /// Replaces the authoritative account configuration using optimistic concurrency.
    /// Once the broker commits, local cache or Keychain failures are represented in
    /// diagnostics while the returned state still reflects the committed account.
    @discardableResult
    public func setConfiguration(
        _ configuration: CmxIrohAccountRelayConfiguration,
        accountID: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date = Date()
    ) async throws -> CmxIrohEffectiveRelayPolicy {
        let operation = beginOperation()
        guard let broker else { throw CmxIrohRelayPolicyServiceError.brokerUnavailable }
        _ = try JSONEncoder().encode(configuration)
        let expectedRevision: Int64?
        if let liveRevision = currentEffective?.preferenceRevision {
            expectedRevision = liveRevision
        } else {
            expectedRevision = try await preferenceStore.load(accountID: accountID)?.revision
        }
        let request = try CmxIrohRelayPreferenceUpdateRequest(
            expectedRevision: expectedRevision,
            preference: configuration
        )
        let response: CmxIrohRelayPreferenceResponse
        do {
            response = try await broker.updateRelayPreference(request)
        } catch {
            if let authoritative = try? await broker.relayPreference() {
                _ = try? await reconcileCommittedConfiguration(
                    authoritative,
                    accountID: accountID,
                    trustRoot: trustRoot,
                    now: now,
                    operation: operation
                )
            }
            throw error
        }
        return try await reconcileCommittedConfiguration(
            response,
            accountID: accountID,
            trustRoot: trustRoot,
            now: now,
            operation: operation
        )
    }

    /// Returns the last authoritative account configuration known in memory.
    public func accountConfiguration() -> CmxIrohAccountRelayConfiguration? {
        currentEffective?.requestedConfiguration
    }

    /// Returns only relay identifiers with configured device-local credentials.
    /// A `nil` result means secure storage could not be read.
    public func configuredCustomCredentialRelayIDs(
        accountID: String
    ) async -> Set<String>? {
        do {
            return try await credentialStore.configuredRelayIDs(accountID: accountID)
        } catch {
            return nil
        }
    }
    private func reconcileCommittedConfiguration(
        _ response: CmxIrohRelayPreferenceResponse,
        accountID: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date,
        operation: UInt64
    ) async throws -> CmxIrohEffectiveRelayPolicy {
        try await Resolver.validatePreferenceRevision(
            response.revision,
            configuration: response.preference,
            accountID: accountID,
            currentEffective: currentEffective,
            preferenceStore: preferenceStore
        )
        let policy = try? await policyCache.load(trustRoot: trustRoot, now: now)
        let resolution = await Resolver.resolve(
            configuration: response.preference,
            revision: response.revision,
            policy: policy,
            accountID: accountID,
            credentialStore: credentialStore,
            usedCachedPolicy: policy != nil,
            now: now
        )
        var failure = resolution.failure
        do {
            _ = try await preferenceStore.install(
                requested: response.preference,
                effective: resolution.effective.effectivePreference,
                revision: response.revision,
                effectivePolicySequence: resolution.effective.managedPolicy?.sequence,
                staleRelayIDs: resolution.effective.staleRelayIDs,
                accountID: accountID
            )
        } catch {
            failure = .preferencePersistenceUnavailable
        }
        if let cleanupFailure = await Resolver.cleanupOrphanCredentials(
            configuration: response.preference,
            accountID: accountID,
            credentialStore: credentialStore
        ) {
            failure = cleanupFailure
        }
        guard isCurrent(operation) else {
            return currentEffective ?? resolution.effective
        }
        publish(resolution.effective, failure: failure)
        return resolution.effective
    }

    /// Saves a device-local custom token and re-resolves the current preference.
    @discardableResult
    public func setStaticCredential(
        _ token: String,
        relayID: String,
        relayURL: String,
        accountID: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date = Date()
    ) async throws -> CmxIrohEffectiveRelayPolicy {
        try await credentialStore.setStaticToken(
            token,
            relayID: relayID,
            relayURL: relayURL,
            accountID: accountID
        )
        return await restore(accountID: accountID, trustRoot: trustRoot, now: now)
    }

    /// Removes a device-local custom token and immediately fails closed if required.
    @discardableResult
    public func removeStaticCredential(
        relayID: String,
        accountID: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date = Date()
    ) async throws -> CmxIrohEffectiveRelayPolicy {
        try await credentialStore.removeCredential(relayID: relayID, accountID: accountID)
        return await restore(accountID: accountID, trustRoot: trustRoot, now: now)
    }

    /// Returns the most recently resolved effective policy.
    public func effectivePolicy() -> CmxIrohEffectiveRelayPolicy? {
        currentEffective
    }

    /// Returns the latest root-verified managed catalog, even during custom mode.
    public func managedPolicy() -> CmxIrohManagedRelayPolicy? {
        currentEffective?.managedPolicy
    }

    /// Returns the latest redacted diagnostics snapshot.
    public func diagnosticsSnapshot() -> CmxIrohRelayDiagnosticsSnapshot {
        currentDiagnostics
    }

    /// Observes redacted diagnostics changes, beginning with the current snapshot.
    public func diagnosticsSnapshots() -> AsyncStream<CmxIrohRelayDiagnosticsSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(currentDiagnostics)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }
    private func publishUnavailable(
        configuration: CmxIrohAccountRelayConfiguration?,
        revision: Int64?,
        source: CmxIrohRelayPolicySource,
        operation: UInt64,
        failure: CmxIrohRelayPolicyFailure
    ) -> CmxIrohEffectiveRelayPolicy {
        let resolution = Resolver.unavailableResolution(
            configuration: configuration,
            revision: revision,
            source: source,
            failure: failure
        )
        return commit(resolution, operation: operation)
    }

    private func commit(
        _ resolution: Resolution,
        operation: UInt64
    ) -> CmxIrohEffectiveRelayPolicy {
        guard isCurrent(operation) else {
            return currentEffective ?? resolution.effective
        }
        publish(resolution.effective, failure: resolution.failure)
        return resolution.effective
    }

    private func beginOperation() -> UInt64 {
        operationRevision &+= 1
        return operationRevision
    }

    private func requireCurrent(_ operation: UInt64) throws {
        guard isCurrent(operation) else {
            throw CmxIrohRelayPolicyServiceError.superseded
        }
    }

    private func isCurrent(_ operation: UInt64) -> Bool {
        operationRevision == operation
    }


    private func publish(
        _ effective: CmxIrohEffectiveRelayPolicy,
        failure: CmxIrohRelayPolicyFailure?
    ) {
        currentEffective = effective
        currentDiagnostics = Resolver.diagnostics(for: effective, failure: failure)
        for continuation in continuations.values {
            continuation.yield(currentDiagnostics)
        }
    }

    private func publishFailure(_ failure: CmxIrohRelayPolicyFailure) {
        guard let effective = currentEffective else {
            currentDiagnostics = CmxIrohRelayDiagnosticsSnapshot(
                source: .inactive,
                policyID: nil,
                policySequence: nil,
                policyExpiresAt: nil,
                preferenceRevision: nil,
                selectedRelayIDs: [],
                selectedRelayCount: 0,
                staleRelayIDs: [],
                missingCredentialRelayIDs: [],
                failure: failure
            )
            for continuation in continuations.values {
                continuation.yield(currentDiagnostics)
            }
            return
        }
        currentDiagnostics = Resolver.diagnostics(for: effective, failure: failure)
        for continuation in continuations.values {
            continuation.yield(currentDiagnostics)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

}

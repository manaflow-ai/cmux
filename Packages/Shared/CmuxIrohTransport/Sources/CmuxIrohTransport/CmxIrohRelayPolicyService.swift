public import CMUXMobileCore
public import Foundation

/// Resolves signed managed policy, account preference, and device-only credentials.
public actor CmxIrohRelayPolicyService {
    private struct Resolution {
        let effective: CmxIrohEffectiveRelayPolicy
        let failure: CmxIrohRelayPolicyFailure?
    }

    private let policyCache: CmxIrohRelayPolicyCache
    private let preferenceStore: CmxIrohRelayPreferenceStore
    private let credentialStore: CmxIrohCustomRelayCredentialStore
    private let broker: (any CmxIrohRelayPolicyServing)?
    private var currentEffective: CmxIrohEffectiveRelayPolicy?
    private var currentDiagnostics = CmxIrohRelayDiagnosticsSnapshot.inactive
    private var continuations: [UUID: AsyncStream<CmxIrohRelayDiagnosticsSnapshot>.Continuation] = [:]
    private var operationRevision: UInt64 = 0

    /// Creates an inactive relay policy service with injected persistence boundaries.
    public init(
        policyCache: CmxIrohRelayPolicyCache = CmxIrohRelayPolicyCache(),
        preferenceStore: CmxIrohRelayPreferenceStore = CmxIrohRelayPreferenceStore(),
        credentialStore: CmxIrohCustomRelayCredentialStore = CmxIrohCustomRelayCredentialStore(),
        broker: (any CmxIrohRelayPolicyServing)? = nil
    ) {
        self.policyCache = policyCache
        self.preferenceStore = preferenceStore
        self.credentialStore = credentialStore
        self.broker = broker
    }

    /// Fetches and installs the broker's current relay bootstrap response.
    @discardableResult
    public func refresh(
        endpointID: CmxIrohPeerIdentity,
        accountID: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date = Date()
    ) async throws -> CmxIrohEffectiveRelayPolicy {
        guard let broker else { throw CmxIrohRelayPolicyServiceError.brokerUnavailable }
        let bootstrap = try await broker.issueRelayBootstrap(endpointID: endpointID)
        return try await install(
            response: bootstrap.relayPolicy,
            accountID: accountID,
            trustRoot: trustRoot,
            relayCredential: bootstrap.relayToken,
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
        relayCredential: CmxIrohRelayTokenResponse?,
        now: Date = Date()
    ) async throws -> CmxIrohEffectiveRelayPolicy {
        let operation = beginOperation()
        do {
            try await validatePreferenceRevision(
                response.preferenceRevision,
                preference: response.preference,
                accountID: accountID
            )
            let policy = try await policyCache.install(
                signedPolicy: response.policy,
                trustRoot: trustRoot,
                now: now
            )
            let resolution = await resolve(
                preference: response.preference,
                revision: response.preferenceRevision,
                policy: policy,
                relayCredential: relayCredential,
                accountID: accountID,
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
            try requireCurrent(operation)
            publish(resolution.effective, failure: resolution.failure)
            return resolution.effective
        } catch {
            if isCurrent(operation) {
                publishFailure(Self.failure(for: error))
            }
            throw error
        }
    }

    /// Restores the last-known-good signed policy and account preference.
    @discardableResult
    public func restore(
        accountID: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        relayCredential: CmxIrohRelayTokenResponse? = nil,
        now: Date = Date()
    ) async -> CmxIrohEffectiveRelayPolicy {
        let operation = beginOperation()
        let persisted: CmxIrohPersistedRelayPreference
        do {
            guard let stored = try await preferenceStore.load(accountID: accountID) else {
                return publishUnavailable(
                    preference: nil,
                    revision: nil,
                    source: .managedUnavailable,
                    operation: operation,
                    failure: .policyUnavailable
                )
            }
            persisted = stored
        } catch {
            return publishUnavailable(
                preference: nil,
                revision: nil,
                source: .managedUnavailable,
                operation: operation,
                failure: .policyUnavailable
            )
        }

        if case .custom = persisted.requested {
            let policy = try? await policyCache.load(trustRoot: trustRoot, now: now)
            let resolution = await resolve(
                preference: persisted.requested,
                revision: persisted.revision,
                policy: policy,
                relayCredential: nil,
                accountID: accountID,
                usedCachedPolicy: policy != nil,
                now: now
            )
            return commit(resolution, operation: operation)
        }

        do {
            guard let policy = try await policyCache.load(trustRoot: trustRoot, now: now) else {
                return publishUnavailable(
                    preference: persisted.requested,
                    revision: persisted.revision,
                    source: .managedUnavailable,
                    operation: operation,
                    failure: .policyUnavailable
                )
            }
            let resolution = await resolve(
                preference: persisted.requested,
                revision: persisted.revision,
                policy: policy,
                relayCredential: relayCredential,
                accountID: accountID,
                usedCachedPolicy: true,
                now: now
            )
            return commit(resolution, operation: operation)
        } catch let error as CmxIrohRelayPolicyError where error == .expired {
            return publishUnavailable(
                preference: persisted.requested,
                revision: persisted.revision,
                source: .managedUnavailable,
                operation: operation,
                failure: .policyExpired
            )
        } catch {
            return publishUnavailable(
                preference: persisted.requested,
                revision: persisted.revision,
                source: .managedUnavailable,
                operation: operation,
                failure: Self.failure(for: error)
            )
        }
    }

    /// Updates the broker preference, then resolves it against cached verified policy.
    @discardableResult
    public func setPreference(
        _ preference: CmxIrohAccountRelayPreference,
        accountID: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        relayCredential: CmxIrohRelayTokenResponse? = nil,
        now: Date = Date()
    ) async throws -> CmxIrohEffectiveRelayPolicy {
        let operation = beginOperation()
        guard let broker else { throw CmxIrohRelayPolicyServiceError.brokerUnavailable }
        _ = try JSONEncoder().encode(preference)
        let expectedRevision = try await preferenceStore.load(accountID: accountID)?.revision
        let request = try CmxIrohRelayPreferenceUpdateRequest(
            expectedRevision: expectedRevision,
            preference: preference
        )
        let response = try await broker.updateRelayPreference(request)
        let policy = try? await policyCache.load(trustRoot: trustRoot, now: now)
        let resolution = await resolve(
            preference: response.preference,
            revision: response.revision,
            policy: policy,
            relayCredential: relayCredential,
            accountID: accountID,
            usedCachedPolicy: policy != nil,
            now: now
        )
        _ = try await preferenceStore.install(
            requested: response.preference,
            effective: resolution.effective.effectivePreference,
            revision: response.revision,
            effectivePolicySequence: resolution.effective.managedPolicy?.sequence,
            staleRelayIDs: resolution.effective.staleRelayIDs,
            accountID: accountID
        )
        try requireCurrent(operation)
        publish(resolution.effective, failure: resolution.failure)
        return resolution.effective
    }

    /// Saves a device-local custom token and re-resolves the current preference.
    @discardableResult
    public func setStaticCredential(
        _ token: String,
        relayID: String,
        accountID: String,
        trustRoot: CmxIrohRelayPolicyTrustRoot,
        now: Date = Date()
    ) async throws -> CmxIrohEffectiveRelayPolicy {
        try await credentialStore.setStaticToken(token, relayID: relayID, accountID: accountID)
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

    private func resolve(
        preference: CmxIrohAccountRelayPreference,
        revision: Int64,
        policy: CmxIrohManagedRelayPolicy?,
        relayCredential: CmxIrohRelayTokenResponse?,
        accountID: String,
        usedCachedPolicy: Bool,
        now: Date
    ) async -> Resolution {
        switch preference {
        case .automatic:
            guard let policy else {
                return unavailableResolution(
                    preference: preference,
                    revision: revision,
                    source: .managedUnavailable,
                    failure: .policyUnavailable
                )
            }
            return resolveManaged(
                selection: .automatic,
                requested: preference,
                effectivePreference: .automatic,
                policy: policy,
                credential: relayCredential,
                staleRelayIDs: [],
                revision: revision,
                usedCachedPolicy: usedCachedPolicy,
                now: now
            )
        case let .managed(requestedIDs):
            guard let policy else {
                return unavailableResolution(
                    preference: preference,
                    revision: revision,
                    source: .managedUnavailable,
                    failure: .policyUnavailable
                )
            }
            let policyIDs = Set(policy.relays.map(\.id))
            let surviving = requestedIDs.intersection(policyIDs)
            let stale = requestedIDs.subtracting(policyIDs)
            guard !surviving.isEmpty else {
                return unavailableResolution(
                    preference: preference,
                    revision: revision,
                    source: .managedUnavailable,
                    staleRelayIDs: stale,
                    policy: policy,
                    usedCachedPolicy: usedCachedPolicy,
                    failure: .staleManagedSelection
                )
            }
            return resolveManaged(
                selection: .only(surviving),
                requested: preference,
                effectivePreference: .managed(surviving),
                policy: policy,
                credential: relayCredential,
                staleRelayIDs: stale,
                revision: revision,
                usedCachedPolicy: usedCachedPolicy,
                now: now
            )
        case let .custom(definitions):
            let tokens: [String: String]
            do {
                tokens = try await credentialStore.staticTokens(accountID: accountID)
            } catch {
                return unavailableResolution(
                    preference: preference,
                    revision: revision,
                    source: .customUnavailable,
                    policy: policy,
                    usedCachedPolicy: usedCachedPolicy,
                    failure: .customCredentialUnavailable
                )
            }
            let missing = Set(definitions.compactMap { definition in
                definition.authMode == .staticToken && tokens[definition.id] == nil
                    ? definition.id
                    : nil
            })
            guard missing.isEmpty else {
                return unavailableResolution(
                    preference: preference,
                    revision: revision,
                    source: .customUnavailable,
                    missingCredentialRelayIDs: missing,
                    policy: policy,
                    usedCachedPolicy: usedCachedPolicy,
                    failure: .missingCustomCredential
                )
            }
            do {
                let relays = try definitions.map { definition in
                    try CmxIrohCustomRelay(
                        url: definition.url,
                        authenticationToken: definition.authMode == .staticToken
                            ? tokens[definition.id]
                            : nil
                    )
                }
                let custom = try CmxIrohCustomRelayProfile(relays: relays)
                return Resolution(
                    effective: CmxIrohEffectiveRelayPolicy(
                        endpointRelayProfile: CmxIrohEndpointRelayProfile(customProfile: custom),
                        managedSnapshot: nil,
                        managedPolicy: policy,
                        requestedPreference: preference,
                        effectivePreference: preference,
                        source: .custom,
                        usedCachedPolicy: usedCachedPolicy,
                        preferenceRevision: revision
                    ),
                    failure: nil
                )
            } catch {
                return unavailableResolution(
                    preference: preference,
                    revision: revision,
                    source: .customUnavailable,
                    policy: policy,
                    usedCachedPolicy: usedCachedPolicy,
                    failure: .policyRejected
                )
            }
        }
    }

    private func resolveManaged(
        selection: CmxIrohManagedRelaySelection,
        requested: CmxIrohAccountRelayPreference,
        effectivePreference: CmxIrohAccountRelayPreference,
        policy: CmxIrohManagedRelayPolicy,
        credential: CmxIrohRelayTokenResponse?,
        staleRelayIDs: Set<String>,
        revision: Int64,
        usedCachedPolicy: Bool,
        now: Date
    ) -> Resolution {
        do {
            let snapshot = try CmxIrohRelayPolicySnapshot(policy: policy, selection: selection)
            var selectedCredentials: [CmxIrohRelayConfiguration] = []
            var failure: CmxIrohRelayPolicyFailure?
            if let credential,
               Set(credential.relayFleet) == Set(policy.relays.map(\.url)),
               credential.relayFleet.count == policy.relays.count,
               let configurations = try? credential.relayConfigurations(now: now) {
                selectedCredentials = configurations.filter { snapshot.relayURLs.contains($0.url) }
            } else {
                failure = .managedCredentialUnavailable
            }
            let profile = try CmxIrohEndpointRelayProfile(
                managedRelayURLs: snapshot.relayURLs,
                relays: selectedCredentials
            )
            return Resolution(
                effective: CmxIrohEffectiveRelayPolicy(
                    endpointRelayProfile: profile,
                    managedSnapshot: snapshot,
                    managedPolicy: policy,
                    requestedPreference: requested,
                    effectivePreference: effectivePreference,
                    staleRelayIDs: staleRelayIDs,
                    source: .managed,
                    usedCachedPolicy: usedCachedPolicy,
                    preferenceRevision: revision
                ),
                failure: failure
            )
        } catch {
            return unavailableResolution(
                preference: requested,
                revision: revision,
                source: .managedUnavailable,
                staleRelayIDs: staleRelayIDs,
                policy: policy,
                usedCachedPolicy: usedCachedPolicy,
                failure: .policyRejected
            )
        }
    }

    private func unavailableResolution(
        preference: CmxIrohAccountRelayPreference?,
        revision: Int64?,
        source: CmxIrohRelayPolicySource,
        staleRelayIDs: Set<String> = [],
        missingCredentialRelayIDs: Set<String> = [],
        policy: CmxIrohManagedRelayPolicy? = nil,
        usedCachedPolicy: Bool = false,
        failure: CmxIrohRelayPolicyFailure
    ) -> Resolution {
        Resolution(
            effective: CmxIrohEffectiveRelayPolicy(
                endpointRelayProfile: source == .customUnavailable
                    ? .unavailableCustomOverride
                    : .unavailableManagedSelection,
                managedSnapshot: nil,
                managedPolicy: policy,
                requestedPreference: preference,
                effectivePreference: nil,
                staleRelayIDs: staleRelayIDs,
                missingCredentialRelayIDs: missingCredentialRelayIDs,
                source: source,
                usedCachedPolicy: usedCachedPolicy,
                preferenceRevision: revision
            ),
            failure: failure
        )
    }

    private func publishUnavailable(
        preference: CmxIrohAccountRelayPreference?,
        revision: Int64?,
        source: CmxIrohRelayPolicySource,
        operation: UInt64,
        failure: CmxIrohRelayPolicyFailure
    ) -> CmxIrohEffectiveRelayPolicy {
        let resolution = unavailableResolution(
            preference: preference,
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

    private func validatePreferenceRevision(
        _ revision: Int64,
        preference: CmxIrohAccountRelayPreference,
        accountID: String
    ) async throws {
        guard let existing = try await preferenceStore.load(accountID: accountID) else { return }
        guard revision > existing.revision
                || (revision == existing.revision && preference == existing.requested) else {
            throw CmxIrohRelayPolicyServiceError.preferenceRollback
        }
    }

    private func publish(
        _ effective: CmxIrohEffectiveRelayPolicy,
        failure: CmxIrohRelayPolicyFailure?
    ) {
        currentEffective = effective
        currentDiagnostics = Self.diagnostics(for: effective, failure: failure)
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
                selectedRelayURLs: [],
                staleRelayIDs: [],
                missingCredentialRelayIDs: [],
                failure: failure
            )
            for continuation in continuations.values {
                continuation.yield(currentDiagnostics)
            }
            return
        }
        currentDiagnostics = Self.diagnostics(for: effective, failure: failure)
        for continuation in continuations.values {
            continuation.yield(currentDiagnostics)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private static func diagnostics(
        for effective: CmxIrohEffectiveRelayPolicy,
        failure: CmxIrohRelayPolicyFailure?
    ) -> CmxIrohRelayDiagnosticsSnapshot {
        let policy = effective.managedPolicy
        let selectedIDs: [String]
        switch effective.effectivePreference {
        case let .managed(ids):
            selectedIDs = ids.sorted()
        case let .custom(relays):
            selectedIDs = relays.map(\.id).sorted()
        case .automatic:
            selectedIDs = effective.managedSnapshot?.relays.map(\.id).sorted() ?? []
        case nil:
            selectedIDs = []
        }
        return CmxIrohRelayDiagnosticsSnapshot(
            source: effective.source,
            policyID: policy?.policyID,
            policySequence: policy?.sequence,
            policyExpiresAt: policy.map { Date(timeIntervalSince1970: TimeInterval($0.expiresAt)) },
            preferenceRevision: effective.preferenceRevision,
            selectedRelayIDs: selectedIDs,
            selectedRelayURLs: effective.endpointRelayProfile.allowedRelayURLs.sorted(),
            staleRelayIDs: effective.staleRelayIDs.sorted(),
            missingCredentialRelayIDs: effective.missingCredentialRelayIDs.sorted(),
            failure: failure
        )
    }

    private static func failure(for error: any Error) -> CmxIrohRelayPolicyFailure {
        if let serviceError = error as? CmxIrohRelayPolicyServiceError,
           serviceError == .preferenceRollback {
            return .preferenceRollback
        }
        guard let policyError = error as? CmxIrohRelayPolicyError else {
            return .policyRejected
        }
        switch policyError {
        case .expired:
            return .policyExpired
        case .rollback:
            return .policyRollback
        default:
            return .policyRejected
        }
    }
}

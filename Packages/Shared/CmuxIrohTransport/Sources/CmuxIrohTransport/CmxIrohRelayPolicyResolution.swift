import CMUXMobileCore
import Foundation

struct CmxIrohRelayPolicyResolutionResult {
    let effective: CmxIrohEffectiveRelayPolicy
    let failure: CmxIrohRelayPolicyFailure?
}

struct CmxIrohRelayPolicyPublication: Equatable, Sendable {
    let policyID: String
    let sequence: Int64
    let issuedAt: Int64

    init(_ policy: CmxIrohManagedRelayPolicy) {
        policyID = policy.policyID
        sequence = policy.sequence
        issuedAt = policy.issuedAt
    }

    init?(policyID: String?, sequence: Int64?, issuedAt: Int64?) {
        guard let policyID,
              let sequence,
              let issuedAt,
              sequence > 0,
              issuedAt >= 0,
              UUID(uuidString: policyID)?.uuidString.lowercased() == policyID else {
            return nil
        }
        self.policyID = policyID
        self.sequence = sequence
        self.issuedAt = issuedAt
    }
}

enum CmxIrohRelayPreferenceRevisionValidation {
    private enum PublicationOrder {
        case olderSequence
        case olderPublication
        case same
        case newer
        case conflicting
    }

    static func validate(
        incomingRevision: Int64,
        incomingConfiguration: CmxIrohAccountRelayConfiguration,
        incomingPublication: CmxIrohRelayPolicyPublication?,
        currentRevision: Int64,
        currentConfiguration: CmxIrohAccountRelayConfiguration,
        currentPublication: CmxIrohRelayPolicyPublication?,
        currentPolicySequence: Int64?
    ) throws {
        guard let incomingPublication,
              let publicationOrder = publicationOrder(
                incoming: incomingPublication,
                current: currentPublication,
                currentPolicySequence: currentPolicySequence
              ) else {
            try requireMonotonicOrIdentical(
                incomingRevision: incomingRevision,
                incomingConfiguration: incomingConfiguration,
                currentRevision: currentRevision,
                currentConfiguration: currentConfiguration
            )
            return
        }

        switch publicationOrder {
        case .olderSequence:
            // The policy cache owns the sequence floor and reports its
            // dedicated rollback error after preference monotonicity passes.
            try requireMonotonicOrIdentical(
                incomingRevision: incomingRevision,
                incomingConfiguration: incomingConfiguration,
                currentRevision: currentRevision,
                currentConfiguration: currentConfiguration
            )
        case .olderPublication:
            throw CmxIrohRelayPolicyServiceError.preferenceRollback
        case .same:
            try requireMonotonicOrIdentical(
                incomingRevision: incomingRevision,
                incomingConfiguration: incomingConfiguration,
                currentRevision: currentRevision,
                currentConfiguration: currentConfiguration
            )
        case .conflicting:
            guard incomingRevision == currentRevision,
                  incomingConfiguration == currentConfiguration else {
                throw CmxIrohRelayPolicyServiceError.preferenceRollback
            }
        case .newer:
            if incomingRevision > currentRevision
                || (incomingRevision == currentRevision
                    && incomingConfiguration == currentConfiguration) {
                return
            }
            guard incomingConfiguration.hasEquivalentActiveAuthority(
                to: currentConfiguration
            ) else {
                throw CmxIrohRelayPolicyServiceError.preferenceRollback
            }
        }
    }

    private static func publicationOrder(
        incoming: CmxIrohRelayPolicyPublication,
        current: CmxIrohRelayPolicyPublication?,
        currentPolicySequence: Int64?
    ) -> PublicationOrder? {
        let sequenceFloor = max(
            currentPolicySequence ?? 0,
            current?.sequence ?? 0
        )
        guard sequenceFloor > 0 else { return nil }
        if incoming.sequence < sequenceFloor { return .olderSequence }
        if incoming.sequence > sequenceFloor { return .newer }
        guard let current, current.sequence == sequenceFloor else { return .same }
        if incoming.issuedAt < current.issuedAt { return .olderPublication }
        if incoming.issuedAt > current.issuedAt { return .newer }
        return incoming.policyID == current.policyID ? .same : .conflicting
    }

    private static func requireMonotonicOrIdentical(
        incomingRevision: Int64,
        incomingConfiguration: CmxIrohAccountRelayConfiguration,
        currentRevision: Int64,
        currentConfiguration: CmxIrohAccountRelayConfiguration
    ) throws {
        guard incomingRevision > currentRevision
                || (incomingRevision == currentRevision
                    && incomingConfiguration == currentConfiguration) else {
            throw CmxIrohRelayPolicyServiceError.preferenceRollback
        }
    }
}

enum CmxIrohRelayPolicyResolution {
    typealias Resolution = CmxIrohRelayPolicyResolutionResult

    static func resolve(
        configuration: CmxIrohAccountRelayConfiguration,
        revision: Int64,
        policy: CmxIrohManagedRelayPolicy?,
        relayCredential: CmxIrohRelayTokenResponse?,
        accountID: String,
        credentialStore: CmxIrohCustomRelayCredentialStore,
        usedCachedPolicy: Bool,
        now: Date
    ) async -> Resolution {
        let preference = configuration.activePreference
        switch preference {
        case .automatic:
            guard let policy else {
                return unavailableResolution(
                    configuration: configuration,
                    revision: revision,
                    source: .managedUnavailable,
                    failure: .policyUnavailable
                )
            }
            return resolveManaged(
                selection: .automatic,
                requestedConfiguration: configuration,
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
                    configuration: configuration,
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
                    configuration: configuration,
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
                requestedConfiguration: configuration,
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
            let authenticatedDefinitions = definitions.filter { $0.authMode == .staticToken }
            if authenticatedDefinitions.isEmpty {
                tokens = [:]
            } else {
                do {
                    tokens = try await credentialStore.staticTokens(
                        for: authenticatedDefinitions,
                        accountID: accountID
                    )
                } catch {
                    return unavailableResolution(
                        configuration: configuration,
                        revision: revision,
                        source: .customUnavailable,
                        policy: policy,
                        usedCachedPolicy: usedCachedPolicy,
                        failure: .customCredentialUnavailable
                    )
                }
            }
            let missing = Set(definitions.compactMap { definition in
                definition.authMode == .staticToken && tokens[definition.id] == nil
                    ? definition.id
                    : nil
            })
            guard missing.isEmpty else {
                return unavailableResolution(
                    configuration: configuration,
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
                        requestedConfiguration: configuration,
                        effectivePreference: preference,
                        source: .custom,
                        usedCachedPolicy: usedCachedPolicy,
                        preferenceRevision: revision
                    ),
                    failure: nil
                )
            } catch {
                return unavailableResolution(
                    configuration: configuration,
                    revision: revision,
                    source: .customUnavailable,
                    policy: policy,
                    usedCachedPolicy: usedCachedPolicy,
                    failure: .policyRejected
                )
            }
        }
    }

    private static func resolveManaged(
        selection: CmxIrohManagedRelaySelection,
        requestedConfiguration: CmxIrohAccountRelayConfiguration,
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
            var relayBootstrap: CmxIrohRelayTokenResponse?
            if let credential,
               Set(credential.relayFleet) == Set(policy.relays.map(\.url)),
               credential.relayFleet.count == policy.relays.count,
               let configurations = try? credential.relayConfigurations(now: now) {
                selectedCredentials = configurations.filter { snapshot.relayURLs.contains($0.url) }
                relayBootstrap = credential
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
                    requestedConfiguration: requestedConfiguration,
                    effectivePreference: effectivePreference,
                    staleRelayIDs: staleRelayIDs,
                    source: .managed,
                    usedCachedPolicy: usedCachedPolicy,
                    preferenceRevision: revision,
                    relayBootstrap: relayBootstrap
                ),
                failure: failure
            )
        } catch {
            return unavailableResolution(
                configuration: requestedConfiguration,
                revision: revision,
                source: .managedUnavailable,
                staleRelayIDs: staleRelayIDs,
                policy: policy,
                usedCachedPolicy: usedCachedPolicy,
                failure: .policyRejected
            )
        }
    }

    static func unavailableResolution(
        configuration: CmxIrohAccountRelayConfiguration?,
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
                requestedConfiguration: configuration,
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

    static func validatePreferenceRevision(
        _ revision: Int64,
        configuration: CmxIrohAccountRelayConfiguration,
        policy: CmxIrohManagedRelayPolicy?,
        legacyPolicy: CmxIrohManagedRelayPolicy?,
        legacyPolicySequence: Int64?,
        accountID: String,
        currentEffective: CmxIrohEffectiveRelayPolicy?,
        preferenceStore: CmxIrohRelayPreferenceStore
    ) async throws {
        let currentRevision = currentEffective?.preferenceRevision
        let currentConfiguration = currentEffective?.requestedConfiguration
        let persisted: CmxIrohPersistedRelayPreference?
        if currentRevision != nil, currentConfiguration != nil {
            persisted = try? await preferenceStore.load(accountID: accountID)
        } else {
            persisted = try await preferenceStore.load(accountID: accountID)
        }
        if let currentRevision, let currentConfiguration {
            let currentPublication: CmxIrohRelayPolicyPublication?
            if let currentPolicy = currentEffective?.managedPolicy {
                currentPublication = CmxIrohRelayPolicyPublication(currentPolicy)
            } else if let persisted {
                currentPublication = CmxIrohRelayPolicyPublication(
                    policyID: persisted.policyID,
                    sequence: persisted.policySequence,
                    issuedAt: persisted.policyIssuedAt
                ) ?? legacyPolicy.map(CmxIrohRelayPolicyPublication.init)
            } else {
                currentPublication = legacyPolicy.map(CmxIrohRelayPolicyPublication.init)
            }
            try CmxIrohRelayPreferenceRevisionValidation.validate(
                incomingRevision: revision,
                incomingConfiguration: configuration,
                incomingPublication: policy.map(CmxIrohRelayPolicyPublication.init),
                currentRevision: currentRevision,
                currentConfiguration: currentConfiguration,
                currentPublication: currentPublication,
                currentPolicySequence: currentEffective?.managedPolicy?.sequence
                    ?? persisted?.policySequence
                    ?? persisted?.effectivePolicySequence
                    ?? legacyPolicySequence
                    ?? legacyPolicy?.sequence
            )
            return
        }
        guard let existing = persisted else { return }
        try CmxIrohRelayPreferenceRevisionValidation.validate(
            incomingRevision: revision,
            incomingConfiguration: configuration,
            incomingPublication: policy.map(CmxIrohRelayPolicyPublication.init),
            currentRevision: existing.revision,
            currentConfiguration: existing.requested,
            currentPublication: CmxIrohRelayPolicyPublication(
                policyID: existing.policyID,
                sequence: existing.policySequence,
                issuedAt: existing.policyIssuedAt
            ) ?? legacyPolicy.map(CmxIrohRelayPolicyPublication.init),
            currentPolicySequence: existing.policySequence
                ?? existing.effectivePolicySequence
                ?? legacyPolicySequence
                ?? legacyPolicy?.sequence
        )
    }

    static func cleanupOrphanCredentials(
        configuration: CmxIrohAccountRelayConfiguration,
        accountID: String,
        credentialStore: CmxIrohCustomRelayCredentialStore
    ) async -> CmxIrohRelayPolicyFailure? {
        do {
            try await credentialStore.retainCredentials(
                for: configuration.customRelays,
                accountID: accountID
            )
            return nil
        } catch {
            return .customCredentialUnavailable
        }
    }

    static func diagnostics(
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
            selectedRelayCount: effective.endpointRelayProfile.allowedRelayURLs.count,
            staleRelayIDs: effective.staleRelayIDs.sorted(),
            missingCredentialRelayIDs: effective.missingCredentialRelayIDs.sorted(),
            failure: failure
        )
    }

    static func failure(for error: any Error) -> CmxIrohRelayPolicyFailure {
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

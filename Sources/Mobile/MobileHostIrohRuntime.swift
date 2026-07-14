import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CryptoKit
import Foundation
import Observation
import OSLog

let mobileHostIrohLog = Logger(
    subsystem: "dev.cmux",
    category: "mobile-host-iroh"
)

/// Publishes live binding state synchronously while secure persistence drains
/// on a lifecycle-cancellable, latest-value serial lane.
@MainActor
final class MobileHostIrohPersistenceQueue {
    typealias Operation = @MainActor @Sendable () async -> Void

    private var pending: Operation?
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0

    func publishAndEnqueue(
        publish: @MainActor () -> Void,
        persist: @escaping Operation
    ) {
        publish()
        pending = persist
        guard worker == nil else { return }
        startWorker(generation: generation)
    }

    func cancel() {
        generation &+= 1
        pending = nil
        worker?.cancel()
        worker = nil
    }

    private func startWorker(generation: UInt64) {
        worker = Task { @MainActor [weak self] in
            await self?.drain(generation: generation)
        }
    }

    private func drain(generation expectedGeneration: UInt64) async {
        while generation == expectedGeneration,
              !Task.isCancelled,
              let operation = pending {
            pending = nil
            await operation()
        }
        guard generation == expectedGeneration else { return }
        worker = nil
        if pending != nil, !Task.isCancelled {
            startWorker(generation: expectedGeneration)
        }
    }
}

/// macOS composition root for the account-scoped Iroh host runtime.
@MainActor
final class MobileHostIrohRuntime {
    enum SettingsError: Error, Equatable {
        case unavailable
        case incompleteCustomRelay
        case missingCustomRelay
    }
    static let shared = MobileHostIrohRuntime()

    static let capabilities = ["mobile-rpc-v1", "multistream-v1"]
    #if DEBUG
    static let debugRelayOnlyDefaultsKey = "cmux.iroh.debug.relay-only"
    #endif

    let appInstances: CmxIrohAppInstanceRepository
    let identities: CmxIrohIdentityRepository
    let brokerCredentials: CmxIrohBrokerCredentialRepository
    let hostPolicies: CmxIrohHostPolicyCache
    let pendingRevocations: CmxIrohPendingRevocationOutbox
    let customRelayProfiles: CmxIrohCustomRelayProfileStore
    let relayPolicyCache: CmxIrohRelayPolicyCache
    let relayPreferenceStore: CmxIrohRelayPreferenceStore
    let customRelayCredentials: CmxIrohCustomRelayCredentialStore
    let relayPolicyTrustRoot: CmxIrohRelayPolicyTrustRoot?
    let lanPublisher: CmxIrohLANHostPublisher
    let authObserver = MobileHostIrohAuthObserver()
    let bindingPersistenceQueue = MobileHostIrohPersistenceQueue()

    weak var auth: AuthCoordinator?
    var authObservationTask: Task<Void, Never>?
    var transitionTask: Task<Void, Never>?
    var runtime: CmxIrohHostRuntime?
    var relayPolicyService: CmxIrohRelayPolicyService?
    var relayPolicyEffective: CmxIrohEffectiveRelayPolicy?
    var relayPolicyDiagnostics: CmxIrohRelayDiagnosticsSnapshot?
    var relayPolicyEndpointID: CmxIrohPeerIdentity?
    var relayPolicyObservationTask: Task<Void, Never>?
    var relayPolicyRefreshTask: Task<Void, Never>?
    var selectedPathObservationTask: Task<Void, Never>?
    var irohSettingsContinuations: [UUID: AsyncStream<CmxIrohSettingsSnapshot>.Continuation] = [:]
    var desiredActive = false
    var observedAccountID: String?
    var activeAccountID: String?
    var activeAppInstanceID: String?
    var lastKnownAccountID: String?
    var lastKnownTag: String?
    var lastKnownBindingID: String?
    var preparedSignOut: CmxIrohHostSignOutPreparation?
    var signOutIntentActive = false
    var signOutPreparationTask: Task<Void, Never>?
    var signOutPreparationRevision: UInt64 = 0
    var lifecycleRevision: UInt64 = 0

    private init() {
        appInstances = CmxIrohAppInstanceRepository()
        #if DEBUG
        identities = CmxIrohIdentityRepository(
            secureStore: CmxIrohDevelopmentFileIdentityStore(
                directory: Self.developmentStoreDirectory(service: "identity")
            )
        )
        brokerCredentials = CmxIrohBrokerCredentialRepository(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(
                    service: "broker-credentials"
                )
            )
        )
        hostPolicies = CmxIrohHostPolicyCache(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(service: "host-policy")
            )
        )
        pendingRevocations = CmxIrohPendingRevocationOutbox(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(
                    service: "pending-revocations"
                )
            )
        )
        customRelayProfiles = CmxIrohCustomRelayProfileStore(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(service: "custom-relays")
            )
        )
        relayPolicyCache = CmxIrohRelayPolicyCache(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(service: "relay-policy")
            )
        )
        relayPreferenceStore = CmxIrohRelayPreferenceStore(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(service: "relay-preference")
            )
        )
        customRelayCredentials = CmxIrohCustomRelayCredentialStore(
            secureStore: CmxIrohDevelopmentFileCredentialStore(
                directory: Self.developmentStoreDirectory(service: "custom-relay-credentials")
            )
        )
        #else
        identities = CmxIrohIdentityRepository()
        brokerCredentials = CmxIrohBrokerCredentialRepository()
        hostPolicies = CmxIrohHostPolicyCache()
        pendingRevocations = CmxIrohPendingRevocationOutbox(
            secureStore: CmxIrohKeychainCredentialStore(
                service: "com.cmuxterm.iroh.pending-revocations.v1"
            )
        )
        customRelayProfiles = CmxIrohCustomRelayProfileStore()
        relayPolicyCache = CmxIrohRelayPolicyCache()
        relayPreferenceStore = CmxIrohRelayPreferenceStore()
        customRelayCredentials = CmxIrohCustomRelayCredentialStore()
        #endif
        relayPolicyTrustRoot = Self.relayPolicyTrustRoot(
            infoDictionary: Bundle.main.infoDictionary
        )
        lanPublisher = CmxIrohLANHostPublisher()
    }

    @discardableResult
    func scheduleReconcile(
        eraseAccountState: Bool,
        restartActiveRuntime: Bool = false
    ) -> Task<Void, Never> {
        lifecycleRevision &+= 1
        bindingPersistenceQueue.cancel()
        let revision = lifecycleRevision
        let previous = transitionTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, revision == self.lifecycleRevision else { return }
            await self.reconcile(
                targetAccountID: self.signOutIntentActive
                    ? nil
                    : (self.desiredActive ? self.observedAccountID : nil),
                eraseAccountState: eraseAccountState || self.signOutIntentActive,
                restartActiveRuntime: restartActiveRuntime,
                revision: revision
            )
            if revision == self.lifecycleRevision {
                self.transitionTask = nil
            }
        }
        transitionTask = task
        return task
    }

    func reconcile(
        targetAccountID: String?,
        eraseAccountState: Bool,
        restartActiveRuntime: Bool,
        revision: UInt64
    ) async {
        if eraseAccountState {
            await quarantineForSignOut()
        } else if restartActiveRuntime
                    || activeAccountID != targetAccountID
                    || targetAccountID == nil {
            let previousRuntime = runtime
            runtime = nil
            selectedPathObservationTask?.cancel()
            selectedPathObservationTask = nil
            activeAccountID = nil
            activeAppInstanceID = nil
            await previousRuntime?.stop()
            await lanPublisher.stop()
            clearRelayPolicyRuntimeState()
        }

        guard revision == lifecycleRevision,
              !Task.isCancelled,
              !signOutIntentActive,
              desiredActive,
              let targetAccountID,
              runtime == nil else { return }

        do {
            try await activate(accountID: targetAccountID, revision: revision)
        } catch is CancellationError {
            return
        } catch {
            mobileHostIrohLog.error(
                "Iroh host activation failed: \(String(describing: error), privacy: .private)"
            )
        }
    }

    func activate(accountID: String, revision: UInt64) async throws {
        guard let auth else { throw CmxIrohHostRuntimeError.inactive }
        let tag = Self.currentTag()
        let appInstanceID = try await appInstances.appInstanceID(
            accountID: accountID,
            tag: tag
        )
        let identity = try await identities.identity(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        let deviceID = MobileHostIdentity.deviceID().lowercased()
        let cachedBinding = try await brokerCredentials.loadBinding(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        guard let derivedEndpointID = identity.peerIdentity else {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
        let bindingMatches = cachedBinding.map {
            $0.deviceID == deviceID
                && $0.appInstanceID == appInstanceID
                && $0.tag == tag
                && $0.platform == .mac
                && derivedEndpointID == $0.endpointID
                && $0.identityGeneration == identity.generation
        } ?? false
        let cachedManagedRelayURLs: Set<String>
        if let relayPolicyTrustRoot,
           let cachedPolicy = try? await relayPolicyCache.load(
               trustRoot: relayPolicyTrustRoot,
               now: Date()
           ) {
            cachedManagedRelayURLs = Set(cachedPolicy.relays.map(\.url))
        } else {
            cachedManagedRelayURLs = []
        }
        let cachedRelay: CmxIrohRelayTokenResponse?
        if let cachedBinding, bindingMatches {
            lastKnownBindingID = cachedBinding.bindingID
            lastKnownAccountID = accountID
            lastKnownTag = tag
            cachedRelay = try await brokerCredentials.loadRelayCredential(
                accountID: accountID,
                binding: cachedBinding,
                expectedRelayFleet: cachedManagedRelayURLs,
                now: Date()
            )
        } else {
            cachedRelay = nil
        }
        let policyExpectation = try CmxIrohHostPolicyExpectation(
            accountID: accountID,
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            tag: tag,
            endpointID: derivedEndpointID,
            identityGeneration: identity.generation,
            pairingEnabled: true,
            capabilities: Self.capabilities
        )
        let cachedHostPolicy: CmxIrohCachedHostPolicy?
        do {
            cachedHostPolicy = try await hostPolicies.load(
                for: policyExpectation,
                now: Date()
            )
        } catch {
            cachedHostPolicy = nil
            mobileHostIrohLog.error(
                "Iroh offline policy load failed: \(String(describing: error), privacy: .private)"
            )
        }
        if let cachedHostPolicy {
            lastKnownBindingID = cachedHostPolicy.binding.bindingID
            lastKnownAccountID = accountID
            lastKnownTag = tag
        }

        let broker = try CmxIrohTrustBrokerClient(
            baseURL: AuthEnvironment.vmAPIBaseURL,
            tokenSource: CmxIrohBrokerTokenSource(
                accessToken: { [weak auth] in
                    guard let auth,
                          let tokens = try? await auth.currentTokens() else { return nil }
                    return tokens.accessToken
                },
                refreshToken: { [weak auth] in
                    guard let auth,
                          let tokens = try? await auth.currentTokens() else { return nil }
                    return tokens.refreshToken
                }
            )
        )
        let endpointRelayProfile: CmxIrohEndpointRelayProfile?
        let managedRelayURLs: Set<String>
        let resolvedPolicyService: CmxIrohRelayPolicyService?
        let resolvedEffectivePolicy: CmxIrohEffectiveRelayPolicy?
        if let relayPolicyTrustRoot {
            let service = CmxIrohRelayPolicyService(
                policyCache: relayPolicyCache,
                preferenceStore: relayPreferenceStore,
                credentialStore: customRelayCredentials,
                broker: broker
            )
            let effective: CmxIrohEffectiveRelayPolicy
            do {
                effective = try await service.refresh(
                    endpointID: derivedEndpointID,
                    accountID: accountID,
                    trustRoot: relayPolicyTrustRoot,
                    now: Date()
                )
            } catch {
                effective = await service.restore(
                    accountID: accountID,
                    trustRoot: relayPolicyTrustRoot,
                    relayCredential: cachedRelay,
                    now: Date()
                )
                mobileHostIrohLog.error(
                    "Signed relay policy refresh failed; restored verified cache: \(String(describing: error), privacy: .private)"
                )
            }
            endpointRelayProfile = effective.endpointRelayProfile
            managedRelayURLs = Set(effective.managedPolicy?.relays.map(\.url) ?? [])
            resolvedPolicyService = service
            resolvedEffectivePolicy = effective
        } else {
            switch await customRelayProfiles.loadSelection() {
            case .managed:
                endpointRelayProfile = nil
            case let .custom(profile):
                endpointRelayProfile = CmxIrohEndpointRelayProfile(customProfile: profile)
            case .customUnavailable:
                mobileHostIrohLog.error(
                    "Custom relay profile unavailable; managed relays remain disabled"
                )
                endpointRelayProfile = .unavailableCustomOverride
            }
            managedRelayURLs = []
            resolvedPolicyService = nil
            resolvedEffectivePolicy = nil
        }
        let compatibleCachedRelay = cachedRelay.flatMap { relay in
            Set(relay.relayFleet) == managedRelayURLs ? relay : nil
        }
        let configuration = CmxIrohHostRuntimeConfiguration(
            accountID: accountID,
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            tag: tag,
            displayName: MobileHostIdentity.instanceDisplayName(),
            identity: identity,
            pairingEnabled: true,
            capabilities: Self.capabilities,
            bindPolicy: .preferred(
                try CmxIrohBindAddress(
                    ipAddress: "0.0.0.0",
                    port: UInt16(MobileHostService.configuredPort())
                )
            ),
            managedRelayURLs: managedRelayURLs,
            endpointRelayProfile: endpointRelayProfile,
            cachedRelayCredential: compatibleCachedRelay,
            cachedHostPolicy: cachedHostPolicy
        )
        let credentialRepository = brokerCredentials
        let hostPolicyCache = hostPolicies
        let lanPublisher = lanPublisher
        let activeRelayPolicyService = resolvedPolicyService
        let hostRuntime = CmxIrohHostRuntime(
            factory: CmxIrohLibEndpointFactory(
                transportVerificationMode: transportVerificationMode
            ),
            broker: broker,
            configuration: configuration,
            pendingRevocations: pendingRevocations,
            protocolConfiguration: protocolConfiguration,
            handleTransport: { session, isCurrent in
                let eventWriter = MobileHostIrohServerEventWriter(
                    session: session
                )
                let laneRouter = MobileHostIrohApplicationLaneRouter(session: session)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await MobileHostService.acceptTransport(
                            session.controlTransport,
                            authorization: .irohAdmission(session.peer),
                            independentEventWriter: eventWriter,
                            isCurrent: isCurrent
                        )
                    }
                    group.addTask {
                        await laneRouter.run(isCurrent: isCurrent)
                    }
                    _ = await group.next()
                    group.cancelAll()
                    await session.close()
                    await laneRouter.stop()
                }
            },
            handleBinding: { [weak self] registration, discovery, attestation in
                let binding = registration.binding
                let metadata = CmxIrohBrokerBindingMetadata(binding: binding)
                guard await self?.allowsPersistence(
                    accountID: accountID,
                    revision: revision
                ) == true else { return }
                await self?.bindingPersistenceQueue.publishAndEnqueue(
                    publish: { [weak self] in
                        self?.recordRegisteredBinding(
                            binding,
                            accountID: accountID,
                            tag: tag,
                            revision: revision
                        )
                    },
                    persist: { [weak self] in
                        guard let self,
                              self.allowsPersistence(
                                  accountID: accountID,
                                  revision: revision
                              ) else { return }
                        try? await credentialRepository.saveBinding(
                            metadata,
                            accountID: accountID
                        )
                        guard self.allowsPersistence(
                            accountID: accountID,
                            revision: revision
                        ) else { return }
                        if let attestation,
                           let discovered = discovery.bindings.first(where: {
                               $0.bindingID == binding.bindingID
                           }) {
                            do {
                                let policy = try CmxIrohCachedHostPolicy(
                                    binding: discovered,
                                    grantVerificationKeys: discovery.grantVerificationKeys,
                                    endpointAttestation: attestation,
                                    lanRendezvous: discovery.lanRendezvous
                                )
                                try await hostPolicyCache.save(
                                    policy,
                                    for: policyExpectation,
                                    now: Date()
                                )
                            } catch {
                                try? await hostPolicyCache.delete(for: policyExpectation)
                                mobileHostIrohLog.error(
                                    "Iroh offline policy cache rejected: \(String(describing: error), privacy: .private)"
                                )
                            }
                        } else if cachedHostPolicy?.binding != metadata {
                            try? await hostPolicyCache.delete(for: policyExpectation)
                        }
                    }
                )
            },
            handleDeactivation: { _ in
                await lanPublisher.stop()
                await MainActor.run {
                    // The runtime owns the local Mac binding, while admitted
                    // sessions carry remote iOS binding IDs. Endpoint teardown
                    // therefore closes every Iroh-authorized connection and
                    // leaves Tailscale/other private-network sessions intact.
                    MobileHostService.shared.closeAllIrohConnections()
                    MobileHostService.shared.updateIrohBinding(nil)
                }
            },
            handleRelayCredential: { [weak self] response, binding in
                guard await self?.allowsPersistence(
                    accountID: accountID,
                    revision: revision
                ) == true else { return }
                let expectedRelayFleet = await activeRelayPolicyService?.managedPolicy()
                    .map { Set($0.relays.map(\.url)) } ?? managedRelayURLs
                try? await credentialRepository.saveRelayCredential(
                    response,
                    accountID: accountID,
                    binding: binding,
                    expectedRelayFleet: expectedRelayFleet,
                    now: Date()
                )
            },
            handleLANRefresh: {
                await lanPublisher.refresh()
            },
            handleLANPolicy: { context, directAddresses in
                await lanPublisher.activate(
                    rendezvous: context.rendezvous,
                    binding: context.binding,
                    directAddresses: directAddresses
                )
            }
        )

        do {
            try await hostRuntime.start()
        } catch {
            if revision != lifecycleRevision || Task.isCancelled {
                runtime = hostRuntime
                activeAccountID = accountID
                activeAppInstanceID = appInstanceID
                throw CancellationError()
            }
            await hostRuntime.stop()
            throw error
        }
        guard revision == lifecycleRevision,
              !Task.isCancelled,
              !signOutIntentActive,
              desiredActive,
              observedAccountID == accountID else {
            // The succeeding reconcile owns this runtime. Retaining it lets a
            // sign-out or account-switch transition capture a binding that was
            // registered while activation was being superseded.
            runtime = hostRuntime
            activeAccountID = accountID
            activeAppInstanceID = appInstanceID
            throw CancellationError()
        }
        runtime = hostRuntime
        activeAccountID = accountID
        activeAppInstanceID = appInstanceID
        relayPolicyService = resolvedPolicyService
        relayPolicyEffective = resolvedEffectivePolicy
        relayPolicyDiagnostics = await resolvedPolicyService?.diagnosticsSnapshot()
        relayPolicyEndpointID = derivedEndpointID
        observeSelectedPathChanges(
            runtime: hostRuntime,
            accountID: accountID,
            revision: revision
        )
        observeRelayPolicyDiagnostics(
            service: resolvedPolicyService,
            accountID: accountID,
            revision: revision
        )
        scheduleRelayPolicyRefresh(
            service: resolvedPolicyService,
            accountID: accountID,
            endpointID: derivedEndpointID,
            trustRoot: relayPolicyTrustRoot,
            revision: revision
        )
        publishIrohSettingsUpdate()
        if preparedSignOut?.pendingRevocation?.accountID == accountID {
            preparedSignOut = nil
        }
    }

    private func recordRegisteredBinding(
        _ binding: CmxIrohBrokerBinding,
        accountID: String,
        tag: String,
        revision: UInt64
    ) {
        guard revision == lifecycleRevision else { return }
        lastKnownBindingID = binding.bindingID
        lastKnownAccountID = accountID
        lastKnownTag = tag
        if preparedSignOut?.pendingRevocation?.accountID == accountID {
            preparedSignOut = nil
        }
        MobileHostService.shared.updateIrohBinding(binding)
    }

    private func allowsPersistence(
        accountID: String,
        revision: UInt64
    ) -> Bool {
        revision == lifecycleRevision
            && !signOutIntentActive
            && desiredActive
            && observedAccountID == accountID
    }

}

extension MobileHostIrohRuntime: CmxIrohSettingsControlling {
    func irohSettingsSnapshot() async -> CmxIrohSettingsSnapshot {
        let service = relayPolicyService
        let effective = await service?.effectivePolicy() ?? relayPolicyEffective
        let diagnostics = await service?.diagnosticsSnapshot() ?? relayPolicyDiagnostics
        let managedPolicy = await service?.managedPolicy() ?? effective?.managedPolicy
        let runtimeState = await runtime?.snapshot().state
        let selectedPath = await runtime?.selectedTransportPath(
            relayPolicy: effective
        ) ?? .unavailable
        let configuration = effective?.requestedConfiguration
        let requested = configuration?.activePreference
        let selectedIDs = configuration?.selectedManagedRelayIDs.isEmpty == false
            ? configuration?.selectedManagedRelayIDs ?? []
            : Set(diagnostics?.selectedRelayIDs ?? [])
        let configuredCredentialIDs = if let service, let activeAccountID {
            await service.configuredCustomCredentialRelayIDs(accountID: activeAccountID)
        } else {
            Optional<Set<String>>.none
        }

        #if DEBUG
        let debugRelayOnlyEnabled: Bool? = Self.isDebugRelayOnlyEnabled
        #else
        let debugRelayOnlyEnabled: Bool? = nil
        #endif
        return CmxIrohSettingsSnapshot(
            runtimeStatus: Self.settingsRuntimeStatus(
                runtimeState,
                failure: diagnostics?.failure,
                selectedPath: selectedPath
            ),
            selectedTransportPath: selectedPath,
            preference: Self.settingsPreference(requested),
            managedRelays: managedPolicy?.relays.map { relay in
                CmxIrohSettingsSnapshot.ManagedRelay(
                    id: relay.id,
                    provider: relay.provider,
                    region: relay.region,
                    url: relay.url,
                    isSelected: selectedIDs.contains(relay.id)
                )
            } ?? [],
            customRelays: Self.settingsCustomRelays(
                configuration: configuration,
                configuredCredentialIDs: configuredCredentialIDs
            ),
            policySource: Self.settingsPolicySource(effective),
            policySequence: diagnostics?.policySequence,
            policyExpiresAt: diagnostics?.policyExpiresAt,
            staleRelayIDs: Set(diagnostics?.staleRelayIDs ?? []),
            failureDescription: diagnostics?.failure?.rawValue,
            debugRelayOnlyEnabled: debugRelayOnlyEnabled
        )
    }

    func irohSettingsUpdates() -> AsyncStream<CmxIrohSettingsSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            irohSettingsContinuations[id] = continuation
            Task { @MainActor [weak self] in
                guard let self else { return }
                continuation.yield(await self.irohSettingsSnapshot())
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.irohSettingsContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func setIrohRelayPreference(
        _ preference: CmxIrohRelayPreferenceDraft
    ) async throws {
        let validated = try preference.validated()
        let context = try relaySettingsContext()
        let current = await context.service.accountConfiguration() ?? .automatic
        let mapped: CmxIrohAccountRelayPreference
        switch validated {
        case .automatic:
            mapped = .automatic
        case let .managed(ids):
            mapped = .managed(ids)
        case .custom:
            guard !current.customRelays.isEmpty else {
                throw SettingsError.incompleteCustomRelay
            }
            mapped = .custom(current.customRelays)
        }
        let effective = try await context.service.setConfiguration(
            current.updatingActivePreference(mapped),
            accountID: context.accountID,
            trustRoot: context.trustRoot,
            now: Date()
        )
        try await applyRelayPolicy(effective)
        await refreshRelayPolicyAfterMutation(context)
    }

    func upsertIrohCustomRelay(
        _ relay: CmxIrohCustomRelayDraft,
        deviceSecret: String?
    ) async throws {
        let context = try relaySettingsContext()
        let current = await context.service.accountConfiguration() ?? .automatic
        var definitions = current.customRelays
        let requestedID = relay.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = (requestedID?.isEmpty == false ? requestedID : nil)?
            .lowercased() ?? UUID().uuidString.lowercased()
        let existingIndex = definitions.firstIndex(where: { $0.id == id })
        let existingDefinition = existingIndex.map { definitions[$0] }
        if relay.authMode == .deviceSecret,
           existingDefinition?.authMode != .staticToken,
           deviceSecret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw SettingsError.incompleteCustomRelay
        }
        let displayName = relay.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let definition = try CmxIrohCustomRelayDefinition(
            id: id,
            url: Self.canonicalRelayURL(relay.url),
            provider: relay.provider.trimmingCharacters(in: .whitespacesAndNewlines),
            region: relay.region.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: displayName.isEmpty ? nil : displayName,
            authMode: relay.authMode == .deviceSecret ? .staticToken : .none
        )
        if let existingIndex {
            definitions[existingIndex] = definition
        } else {
            definitions.append(definition)
        }
        var effective = try await context.service.setConfiguration(
            current.replacingCustomRelays(definitions),
            accountID: context.accountID,
            trustRoot: context.trustRoot,
            now: Date()
        )
        try await applyRelayPolicy(effective)
        if definition.authMode == .staticToken, let deviceSecret {
            effective = try await context.service.setStaticCredential(
                deviceSecret,
                relayID: definition.id,
                accountID: context.accountID,
                trustRoot: context.trustRoot,
                now: Date()
            )
            try await applyRelayPolicy(effective)
        }
        await refreshRelayPolicyAfterMutation(context)
    }

    func removeIrohCustomRelay(id: String) async throws {
        let context = try relaySettingsContext()
        let current = await context.service.accountConfiguration() ?? .automatic
        guard current.customRelays.contains(where: { $0.id == id }) else {
            throw SettingsError.missingCustomRelay
        }
        let remaining = current.customRelays.filter { $0.id != id }
        let effective = try await context.service.setConfiguration(
            current.replacingCustomRelays(remaining),
            accountID: context.accountID,
            trustRoot: context.trustRoot,
            now: Date()
        )
        try await applyRelayPolicy(effective)
        await refreshRelayPolicyAfterMutation(context)
    }

    func testIrohCustomRelay(id: String) async -> CmxIrohRelayTestResult {
        guard let effective = await relayPolicyService?.effectivePolicy(),
              let definition = effective.requestedConfiguration?.customRelays.first(where: {
                  $0.id == id
              }),
              !effective.missingCredentialRelayIDs.contains(id) else {
            return .incomplete
        }
        // A provider may bind its device secret to the live endpoint identity.
        // A throwaway endpoint would then produce a misleading false failure.
        guard definition.authMode == .none,
              let relay = try? CmxIrohCustomRelay(url: definition.url),
              let profile = try? CmxIrohCustomRelayProfile(relays: [relay]) else {
            return .incomplete
        }
        switch await CmxIrohCustomRelayProbe().probe(
            profile: CmxIrohEndpointRelayProfile(customProfile: profile)
        ) {
        case .reachable:
            return .reachable(latencyMilliseconds: nil)
        case .invalidProfile, .bindFailed, .endpointClosed, .timedOut:
            return .failed
        }
    }

    func refreshIrohSettings() async {
        guard let context = try? relaySettingsContext() else {
            publishIrohSettingsUpdate()
            return
        }
        do {
            let effective = try await context.service.refresh(
                endpointID: context.endpointID,
                accountID: context.accountID,
                trustRoot: context.trustRoot,
                now: Date()
            )
            try await applyRelayPolicy(effective)
        } catch {
            relayPolicyDiagnostics = await context.service.diagnosticsSnapshot()
            publishIrohSettingsUpdate()
        }
    }

    func observeRelayPolicyDiagnostics(
        service: CmxIrohRelayPolicyService?,
        accountID: String,
        revision: UInt64
    ) {
        relayPolicyObservationTask?.cancel()
        guard let service else { return }
        relayPolicyObservationTask = Task { @MainActor [weak self] in
            let snapshots = await service.diagnosticsSnapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled,
                      let self,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID else { return }
                self.relayPolicyDiagnostics = snapshot
                self.relayPolicyEffective = await service.effectivePolicy()
                self.publishIrohSettingsUpdate()
            }
        }
    }

    func observeSelectedPathChanges(
        runtime: CmxIrohHostRuntime,
        accountID: String,
        revision: UInt64
    ) {
        selectedPathObservationTask?.cancel()
        selectedPathObservationTask = Task { @MainActor [weak self] in
            let changes = await runtime.selectedTransportPathChanges()
            for await _ in changes {
                guard !Task.isCancelled,
                      let self,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID,
                      self.runtime === runtime else { return }
                self.publishIrohSettingsUpdate()
            }
        }
    }

    /// Refreshes the signed relay catalog before expiry and removes relay
    /// authority at expiry when the broker remains unavailable. The live Iroh
    /// endpoint and authenticated sessions stay intact, so direct paths remain
    /// usable while a later retry can restore relay service.
    func scheduleRelayPolicyRefresh(
        service: CmxIrohRelayPolicyService?,
        accountID: String,
        endpointID: CmxIrohPeerIdentity,
        trustRoot: CmxIrohRelayPolicyTrustRoot?,
        revision: UInt64
    ) {
        relayPolicyRefreshTask?.cancel()
        guard let service, let trustRoot else {
            relayPolicyRefreshTask = nil
            return
        }
        relayPolicyRefreshTask = Task { @MainActor [weak self] in
            var retryAt: Date?
            var failureCount = 0
            var relayAuthorityExpired = false
            while !Task.isCancelled {
                guard let self,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID,
                      self.relayPolicyService === service else { return }
                let snapshot = await service.diagnosticsSnapshot()
                let current = Date()
                let attemptAt = Self.relayPolicyRefreshAttemptDate(
                    policyExpiresAt: relayAuthorityExpired
                        ? nil
                        : snapshot.policyExpiresAt,
                    retryAt: retryAt,
                    now: current
                )
                let delay = attemptAt.timeIntervalSince(current)
                if delay > 0 {
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                }
                let wakeDate = Date()
                if let retryAt,
                   retryAt > wakeDate,
                   Self.shouldDeactivateRelayPolicy(
                       policyExpiresAt: snapshot.policyExpiresAt,
                       now: wakeDate
                   ) {
                    let expired = await service.restore(
                        accountID: accountID,
                        trustRoot: trustRoot,
                        now: wakeDate
                    )
                    try? await self.applyRelayPolicy(expired)
                    relayAuthorityExpired = true
                    continue
                }
                guard !Task.isCancelled,
                      revision == self.lifecycleRevision,
                      self.activeAccountID == accountID,
                      self.relayPolicyService === service else { return }
                do {
                    let effective = try await service.refresh(
                        endpointID: endpointID,
                        accountID: accountID,
                        trustRoot: trustRoot,
                        now: Date()
                    )
                    try await self.applyRelayPolicy(effective)
                    retryAt = nil
                    failureCount = 0
                    relayAuthorityExpired = false
                } catch {
                    let failureDate = Date()
                    if Self.shouldDeactivateRelayPolicy(
                        policyExpiresAt: snapshot.policyExpiresAt,
                        now: failureDate
                    ) {
                        let expired = await service.restore(
                            accountID: accountID,
                            trustRoot: trustRoot,
                            now: failureDate
                        )
                        try? await self.applyRelayPolicy(expired)
                        relayAuthorityExpired = true
                    } else {
                        self.relayPolicyDiagnostics = await service.diagnosticsSnapshot()
                        self.publishIrohSettingsUpdate()
                    }
                    let retryDelay = CmxIrohRetrySchedule().delay(
                        failureCount: failureCount,
                        retryAfterSeconds: (error as? CmxIrohTrustBrokerClientError)?
                            .retryAfterSeconds,
                        jitterUnitInterval: Double.random(in: 0 ... 1)
                    )
                    failureCount = min(failureCount + 1, 20)
                    retryAt = failureDate.addingTimeInterval(retryDelay)
                }
            }
        }
    }

    nonisolated static func relayPolicyRefreshAttemptDate(
        policyExpiresAt: Date?,
        retryAt: Date?,
        now: Date
    ) -> Date {
        if let retryAt {
            return min(retryAt, policyExpiresAt ?? retryAt)
        }
        if let policyExpiresAt {
            return policyExpiresAt.addingTimeInterval(-60)
        }
        return now.addingTimeInterval(30)
    }

    nonisolated static func shouldDeactivateRelayPolicy(
        policyExpiresAt: Date?,
        now: Date
    ) -> Bool {
        guard let policyExpiresAt else { return false }
        return now >= policyExpiresAt
    }

    func publishIrohSettingsUpdate() {
        guard !irohSettingsContinuations.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await self.irohSettingsSnapshot()
            for continuation in self.irohSettingsContinuations.values {
                continuation.yield(snapshot)
            }
        }
    }

    private func relaySettingsContext() throws -> (
        service: CmxIrohRelayPolicyService,
        accountID: String,
        endpointID: CmxIrohPeerIdentity,
        trustRoot: CmxIrohRelayPolicyTrustRoot
    ) {
        guard let relayPolicyService,
              let activeAccountID,
              let relayPolicyEndpointID,
              let relayPolicyTrustRoot else { throw SettingsError.unavailable }
        return (
            relayPolicyService,
            activeAccountID,
            relayPolicyEndpointID,
            relayPolicyTrustRoot
        )
    }

    private func refreshRelayPolicyAfterMutation(
        _ context: (
            service: CmxIrohRelayPolicyService,
            accountID: String,
            endpointID: CmxIrohPeerIdentity,
            trustRoot: CmxIrohRelayPolicyTrustRoot
        )
    ) async {
        do {
            let effective = try await context.service.refresh(
                endpointID: context.endpointID,
                accountID: context.accountID,
                trustRoot: context.trustRoot,
                now: Date()
            )
            try await applyRelayPolicy(effective)
        } catch {
            relayPolicyDiagnostics = await context.service.diagnosticsSnapshot()
            publishIrohSettingsUpdate()
        }
    }

    private func applyRelayPolicy(
        _ effective: CmxIrohEffectiveRelayPolicy
    ) async throws {
        relayPolicyEffective = effective
        relayPolicyDiagnostics = await relayPolicyService?.diagnosticsSnapshot()
        if let runtime {
            try await runtime.replaceRelayPolicy(effective)
        }
        publishIrohSettingsUpdate()
    }

    func clearRelayPolicyRuntimeState() {
        relayPolicyObservationTask?.cancel()
        relayPolicyObservationTask = nil
        relayPolicyRefreshTask?.cancel()
        relayPolicyRefreshTask = nil
        relayPolicyService = nil
        relayPolicyEffective = nil
        relayPolicyDiagnostics = nil
        relayPolicyEndpointID = nil
        publishIrohSettingsUpdate()
    }

    private nonisolated static func settingsRuntimeStatus(
        _ state: CmxIrohHostRuntimeSnapshot.State?,
        failure: CmxIrohRelayPolicyFailure?,
        selectedPath: CmxIrohSelectedTransportPath
    ) -> CmxIrohSettingsSnapshot.RuntimeStatus {
        if failure != nil { return .degraded }
        switch state {
        case .active:
            return CmxIrohSettingsSnapshot.RuntimeStatus(activePath: selectedPath)
        case .starting:
            return .starting
        case .failed, .quarantined:
            return .degraded
        case .inactive, .stopping, .signingOut, nil:
            return .inactive
        }
    }

    private nonisolated static func settingsPreference(
        _ preference: CmxIrohAccountRelayPreference?
    ) -> CmxIrohRelayPreferenceDraft {
        switch preference {
        case .automatic, nil:
            return .automatic
        case let .managed(ids):
            return .managed(ids)
        case .custom:
            return .custom
        }
    }

    private nonisolated static func settingsCustomRelays(
        configuration: CmxIrohAccountRelayConfiguration?,
        configuredCredentialIDs: Set<String>?
    ) -> [CmxIrohSettingsSnapshot.CustomRelay] {
        configuration?.customRelays.map { relay in
            let credentialState: CmxIrohSettingsSnapshot.CredentialState
            if relay.authMode == .none {
                credentialState = .notRequired
            } else if configuredCredentialIDs == nil {
                credentialState = .unavailable
            } else {
                credentialState = configuredCredentialIDs?.contains(relay.id) == true
                    ? .configured
                    : .missing
            }
            return CmxIrohSettingsSnapshot.CustomRelay(
                id: relay.id,
                displayName: relay.displayName ?? relay.id,
                provider: relay.provider,
                region: relay.region,
                url: relay.url,
                authMode: relay.authMode == .staticToken ? .deviceSecret : .none,
                credentialState: credentialState
            )
        } ?? []
    }

    private nonisolated static func settingsPolicySource(
        _ effective: CmxIrohEffectiveRelayPolicy?
    ) -> CmxIrohSettingsSnapshot.PolicySource {
        guard let effective else { return .unavailable }
        return effective.usedCachedPolicy ? .cached : .server
    }

    private nonisolated static func canonicalRelayURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return trimmed }
        components.host = components.host?.lowercased()
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? trimmed
    }
}

private extension CmxIrohIdentityMaterial {
    var peerIdentity: CmxIrohPeerIdentity? {
        guard let privateKey = try? Curve25519.Signing.PrivateKey(
            rawRepresentation: secretKey.bytes
        ) else { return nil }
        let endpointID = privateKey.publicKey.rawRepresentation
            .map { String(format: "%02x", $0) }
            .joined()
        return try? CmxIrohPeerIdentity(endpointID: endpointID)
    }
}

extension MobileHostIrohRuntime {
    /// Reads only app-bundled public verification keys. Broker responses never
    /// become trust roots, so a missing or malformed build configuration keeps
    /// dynamic managed policy unavailable instead of accepting an unsigned fleet.
    nonisolated static func relayPolicyTrustRoot(
        infoDictionary: [String: Any]?
    ) -> CmxIrohRelayPolicyTrustRoot? {
        CmxIrohRelayPolicyTrustRoot.appPinned(infoDictionary: infoDictionary)
    }
}

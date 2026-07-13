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

/// macOS composition root for the account-scoped Iroh host runtime.
@MainActor
final class MobileHostIrohRuntime {
    static let shared = MobileHostIrohRuntime()

    static let relayDeployment = CmxIrohRelayDeployment.current
    static let managedRelayURLs = relayDeployment.urls
    static let capabilities = ["mobile-rpc-v1", "multistream-v1"]

    let appInstances: CmxIrohAppInstanceRepository
    let identities: CmxIrohIdentityRepository
    let brokerCredentials: CmxIrohBrokerCredentialRepository
    let hostPolicies: CmxIrohHostPolicyCache
    let pendingRevocations: CmxIrohPendingRevocationOutbox
    let customRelayProfiles: CmxIrohCustomRelayProfileStore
    let lanPublisher: CmxIrohLANHostPublisher
    let authObserver = MobileHostIrohAuthObserver()

    weak var auth: AuthCoordinator?
    var authObservationTask: Task<Void, Never>?
    var transitionTask: Task<Void, Never>?
    var runtime: CmxIrohHostRuntime?
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
        #endif
        lanPublisher = CmxIrohLANHostPublisher()
    }

    @discardableResult
    func scheduleReconcile(
        eraseAccountState: Bool
    ) -> Task<Void, Never> {
        lifecycleRevision &+= 1
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
        revision: UInt64
    ) async {
        if eraseAccountState {
            await quarantineForSignOut()
        } else if activeAccountID != targetAccountID || targetAccountID == nil {
            let previousRuntime = runtime
            runtime = nil
            activeAccountID = nil
            activeAppInstanceID = nil
            await previousRuntime?.stop()
            await lanPublisher.stop()
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
        let cachedRelay: CmxIrohRelayTokenResponse?
        if let cachedBinding, bindingMatches {
            lastKnownBindingID = cachedBinding.bindingID
            lastKnownAccountID = accountID
            lastKnownTag = tag
            cachedRelay = try await brokerCredentials.loadRelayCredential(
                accountID: accountID,
                binding: cachedBinding,
                expectedRelayFleet: Self.managedRelayURLs,
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
            ),
            relayTokenEndpoint: Self.relayDeployment.tokenEndpoint
        )
        let endpointRelayProfile: CmxIrohEndpointRelayProfile?
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
        let configuration = CmxIrohHostRuntimeConfiguration(
            accountID: accountID,
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            tag: tag,
            displayName: MobileHostIdentity.displayName(),
            identity: identity,
            pairingEnabled: true,
            capabilities: Self.capabilities,
            bindPolicy: .preferred(
                try CmxIrohBindAddress(
                    ipAddress: "0.0.0.0",
                    port: UInt16(MobileHostService.configuredPort())
                )
            ),
            managedRelayURLs: Self.managedRelayURLs,
            endpointRelayProfile: endpointRelayProfile,
            cachedRelayCredential: cachedRelay,
            cachedHostPolicy: cachedHostPolicy
        )
        let credentialRepository = brokerCredentials
        let hostPolicyCache = hostPolicies
        let lanPublisher = lanPublisher
        let managedRelayURLs = Self.managedRelayURLs
        let hostRuntime = CmxIrohHostRuntime(
            factory: CmxIrohLibEndpointFactory(),
            broker: broker,
            configuration: configuration,
            pendingRevocations: pendingRevocations,
            handleTransport: { session, isCurrent in
                let eventWriter = MobileHostIrohServerEventWriter(
                    session: session
                )
                await MobileHostService.acceptTransport(
                    session.controlTransport,
                    authorization: .irohAdmission(session.peer),
                    independentEventWriter: eventWriter,
                    isCurrent: isCurrent
                )
            },
            handleBinding: { [weak self] registration, discovery, attestation in
                let binding = registration.binding
                let metadata = CmxIrohBrokerBindingMetadata(binding: binding)
                try? await credentialRepository.saveBinding(
                    metadata,
                    accountID: accountID
                )
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
                await self?.recordRegisteredBinding(
                    binding,
                    accountID: accountID,
                    tag: tag,
                    revision: revision
                )
            },
            handleDeactivation: { bindingID in
                await lanPublisher.stop()
                await MainActor.run {
                    if let bindingID {
                        MobileHostService.shared.closeIrohConnections(
                            bindingID: bindingID
                        )
                    }
                    MobileHostService.shared.updateIrohBinding(nil)
                }
            },
            handleRelayCredential: { response, binding in
                try? await credentialRepository.saveRelayCredential(
                    response,
                    accountID: accountID,
                    binding: binding,
                    expectedRelayFleet: managedRelayURLs,
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

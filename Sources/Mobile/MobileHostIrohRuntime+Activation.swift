import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CryptoKit
import Foundation

@MainActor
extension MobileHostIrohRuntime {
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
        let deviceID = cmxCanonicalDeviceID(MobileHostIdentity.deviceID())
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

        guard let brokerBaseURL = AuthEnvironment.irohBrokerBaseURL else {
            throw CmxIrohTrustBrokerClientError.invalidBaseURL
        }
        let broker = try CmxIrohTrustBrokerClient(
            baseURL: brokerBaseURL,
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
            diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshStarted))
            do {
                effective = try await service.refresh(
                    endpointID: derivedEndpointID,
                    accountID: accountID,
                    trustRoot: relayPolicyTrustRoot,
                    now: Date()
                )
                diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshSucceeded))
            } catch {
                diagnosticLog.record(DiagnosticEvent(
                    .relayPolicyRefreshFailed,
                    b: Self.diagnosticFailureKind(for: error).rawValue
                ))
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
            handleTransport: { [diagnosticLog] session, isCurrent in
                diagnosticLog.record(DiagnosticEvent(
                    .admissionSucceeded,
                    a: DiagnosticTransportKind.iroh.rawValue
                ))
                let eventWriter = MobileHostIrohServerEventWriter(
                    session: session
                )
                let artifactTransfers = MobileHostIrohArtifactTransferRegistry()
                let laneRouter = MobileHostIrohApplicationLaneRouter(
                    session: session,
                    artifactHandler: MobileHostIrohArtifactLaneHandler(
                        registry: artifactTransfers
                    )
                )
                let connectionSupervisor = CmxIrohAdmittedConnectionSupervisor(
                    runControl: {
                        await MobileHostService.acceptTransport(
                            session.controlTransport,
                            authorization: .irohAdmission(session.peer),
                            artifactTransfers: artifactTransfers,
                            independentEventWriter: eventWriter,
                            isCurrent: isCurrent
                        )
                    },
                    runApplicationLanes: {
                        await laneRouter.run(isCurrent: isCurrent)
                    },
                    closeConnection: {
                        await session.close()
                    },
                    stopApplicationLanes: {
                        await laneRouter.stop()
                    }
                )
                await connectionSupervisor.run()
                diagnosticLog.record(DiagnosticEvent(
                    .sessionClosed,
                    a: DiagnosticTransportKind.iroh.rawValue
                ))
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
                guard MobileHostService.isListeningEnabled else {
                    await lanPublisher.stop()
                    return
                }
                await lanPublisher.refresh()
            },
            handleLANPolicy: { context, directAddresses in
                guard MobileHostService.isListeningEnabled else {
                    await lanPublisher.stop()
                    return
                }
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
        diagnosticLog.record(DiagnosticEvent(
            .endpointActive,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
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

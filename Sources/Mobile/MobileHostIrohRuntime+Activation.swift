import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import Foundation

@MainActor
extension MobileHostIrohRuntime {
    func activate(accountID: String, revision: UInt64) async throws {
        beginIrohRouteActivation(revision: revision)
        guard let auth else { throw CmxIrohHostRuntimeError.inactive }
        // Pin the runtime's broker to the session identity that owns
        // `accountID` — a cheap local check now, and every broker request
        // below re-reads an ATOMIC authenticated snapshot validated against
        // this pin. An A→B account switch therefore makes the old runtime's
        // requests fail closed immediately instead of pairing B's credentials
        // with A's endpoint/device state (registering or refreshing a binding
        // under B and caching it as A) before lifecycle reconciliation runs.
        guard auth.currentUser?.id == accountID else {
            throw CmxIrohHostRuntimeError.inactive
        }
        let tag = Self.currentTag()
        guard let clientNamespace = CmxIrohMacBundleNamespace(
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) else {
            throw CmxIrohHostRuntimeError.invalidLocalBinding
        }
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
                && $0.clientNamespace == clientNamespace.rawValue
                && $0.tag == tag
                && $0.platform == .mac
                && derivedEndpointID == $0.endpointID
                && $0.identityGeneration == identity.generation
        } ?? false
        if let cachedBinding, bindingMatches {
            lastKnownBindingID = cachedBinding.bindingID
            lastKnownAccountID = accountID
            lastKnownTag = tag
        }
        let policyExpectation = try CmxIrohHostPolicyExpectation(
            accountID: accountID,
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            clientNamespace: clientNamespace.rawValue,
            tag: tag,
            endpointID: derivedEndpointID,
            identityGeneration: identity.generation,
            // Under a managed remote-control disable the runtime should never
            // activate at all; reporting pairingEnabled=false is defense in
            // depth so the trust broker also refuses to mint pair grants.
            pairingEnabled: MobileRemoteControlPolicy.isEnabled,
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
        let rawBroker = try CmxIrohTrustBrokerClient(
            baseURL: brokerBaseURL,
            tokenSource: .accountPinned(
                to: accountID,
                // An ATOMIC authenticated snapshot per fetch, validated
                // against the activation's ACCOUNT pin: identity and
                // credentials come from one transition-checked capture, so an
                // account switch completing while the read is suspended can
                // never hand this runtime a DIFFERENT account's credentials,
                // and the pin fails requests closed the moment the account
                // changes. Deliberately NOT generation-pinned: every completed
                // sign-in advances the generation, and a same-account
                // re-sign-in must keep this long-lived runtime serviceable —
                // it is still the same user, so serving the new session's
                // credentials is correct, whereas a generation pin would
                // strand the runtime on nil credentials until relaunch. The
                // snapshot's pair capture is store-level (no network while the
                // stored access token is valid).
                snapshot: { [weak auth] in
                    guard let auth else { return nil }
                    let session: AuthenticatedSessionSnapshot
                    do {
                        session = try await auth.authenticatedSessionSnapshot()
                    } catch AuthError.unauthorized {
                        // Definitively signed out: fail closed.
                        return nil
                    }
                    // Transient failures (a revalidation owns the token
                    // store, a re-mint is in flight or offline) rethrow so
                    // the broker classifies them connectivity instead of
                    // tearing the host runtime down as unauthorized.
                    return CmxIrohAccountCredentialSnapshot(
                        accountID: session.accountID,
                        credentials: CmxIrohBrokerCredentials(
                            accessToken: session.accessToken,
                            refreshToken: session.refreshToken
                        )
                    )
                },
                forceRefresh: { [weak auth] in
                    guard let auth else { return }
                    _ = try await auth.forceRefreshAccessToken()
                }
            ),
            clientNamespace: clientNamespace.rawValue,
            discoveryScope: try CmxConnectivityDiscoveryScope(
                deviceID: deviceID,
                appInstanceID: appInstanceID,
                tag: tag,
                platform: .mac,
                peerPlatform: .ios
            ),
            backpressureMode: .callerOwned
        )
        let broker = CmxIrohBackpressuredHostBroker(
            broker: rawBroker,
            gate: brokerBackpressureGate,
            accountID: accountID
        )
        let relayPolicyBroker = CmxIrohBackpressuredRelayPolicyBroker(
            broker: rawBroker,
            gate: brokerBackpressureGate,
            accountID: accountID
        )
        let endpointRelayProfile: CmxIrohEndpointRelayProfile?
        let managedRelayURLs: Set<String>
        let resolvedPolicyService: CmxIrohRelayPolicyService?
        let resolvedEffectivePolicy: CmxIrohEffectiveRelayPolicy?
        var relayPolicyNeedsImmediateRefresh = false
        if let relayPolicyTrustRoot {
            let service = CmxIrohRelayPolicyService(
                policyCache: relayPolicyCache,
                preferenceStore: relayPreferenceStore,
                credentialStore: customRelayCredentials,
                broker: relayPolicyBroker
            )
            let effective: CmxIrohEffectiveRelayPolicy
            if protocolConfiguration.allowsNATTraversalAfterAdmission {
                // A verified cached policy is sufficient to bind, register,
                // and discover. Refresh it immediately after activation so
                // broker latency never gates direct-path availability.
                effective = await service.restore(
                    accountID: accountID,
                    trustRoot: relayPolicyTrustRoot,
                    now: Date()
                )
                relayPolicyNeedsImmediateRefresh = true
            } else {
                // Relay-only verification cannot become active without the
                // current signed fleet, so keep its explicit readiness barrier.
                diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshStarted))
                do {
                    effective = try await service.refresh(
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
                        now: Date()
                    )
                    relayPolicyNeedsImmediateRefresh = true
                }
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
        let configuration = CmxIrohHostRuntimeConfiguration(
            accountID: accountID,
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            clientNamespace: clientNamespace,
            tag: tag,
            displayName: MobileHostIdentity.instanceDisplayName(),
            identity: identity,
            // Under a managed remote-control disable the runtime should never
            // activate at all; reporting pairingEnabled=false is defense in
            // depth so the trust broker also refuses to mint pair grants.
            pairingEnabled: MobileRemoteControlPolicy.isEnabled,
            capabilities: Self.capabilities,
            bindPolicy: .preferred(
                try CmxIrohBindAddress(
                    ipAddress: "0.0.0.0",
                    port: UInt16(MobileHostService.configuredPort())
                )
            ),
            managedRelayURLs: managedRelayURLs,
            endpointRelayProfile: endpointRelayProfile,
            cachedHostPolicy: cachedHostPolicy
        )
        let credentialRepository = brokerCredentials
        let hostPolicyCache = hostPolicies
        let lanPublisher = lanPublisher
        let hostRuntime = CmxIrohHostRuntime(
            factory: CmxIrohLibEndpointFactory(
                transportVerificationMode: transportVerificationMode
            ),
            broker: broker,
            configuration: configuration,
            pendingRevocations: pendingRevocations,
            protocolConfiguration: protocolConfiguration,
            handleTransport: { [weak self] session, isCurrent in
                guard let self else {
                    await session.close()
                    return
                }
                let diagnosticSessionID = await self.makeDiagnosticSessionID()
                let diagnosticLog = self.diagnosticLog
                diagnosticLog.record(DiagnosticEvent(
                    .admissionSucceeded,
                    a: DiagnosticTransportKind.iroh.rawValue
                ))
                CmuxEventBus.shared.publish(
                    name: "mobile.iroh.admission.succeeded",
                    category: "mobile",
                    source: "mobile.iroh.host"
                )
                diagnosticLog.record(DiagnosticEvent(
                    .transportSessionLifecycle,
                    a: DiagnosticSessionLifecycleKind.established.rawValue,
                    b: Int(CmxTransportSessionPurpose.foregroundControl.rawValue),
                    c: diagnosticSessionID
                ))
                let connectionDiagnostics = CmxIrohConnectionDiagnosticRecorder(
                    diagnosticLog: diagnosticLog,
                    sessionID: diagnosticSessionID
                )
                let pathEvents = await session.observedPathEvents()
                let pathEventTask = Task {
                    for await event in pathEvents {
                        guard !Task.isCancelled else { return }
                        connectionDiagnostics.record(event)
                    }
                }
                let eventWriter = MobileHostIrohServerEventWriter(
                    session: session
                )
                let artifactTransfers = MobileHostIrohArtifactTransferRegistry()
                let laneRouter = MobileHostIrohApplicationLaneRouter(
                    session: session,
                    artifactHandler: MobileHostIrohArtifactLaneHandler(
                        registry: artifactTransfers
                    ),
                    simulatorStreamHandler: MobileHostIrohSimulatorStreamLaneHandler()
                )
                let connectionSupervisor = CmxIrohAdmittedConnectionSupervisor(
                    runControl: {
                        await MobileHostService.acceptTransport(
                            session.controlTransport,
                            authorization: .irohAdmission(session.peer),
                            artifactTransfers: artifactTransfers,
                            independentEventWriter: eventWriter,
                            promoteUsableSession: {
                                await session.markUsable()
                            },
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
                let observedExit = await connectionSupervisor.run()
                let exit = await session.connectionExit(resolving: observedExit)
                await pathEventTask.value
                connectionDiagnostics.record(await session.closeAttribution())
                diagnosticLog.record(DiagnosticEvent(
                    .transportSessionLifecycle,
                    a: exit.lifecycle.rawValue,
                    b: Int(CmxTransportSessionPurpose.foregroundControl.rawValue),
                    c: diagnosticSessionID
                ))
                diagnosticLog.record(DiagnosticEvent(
                    .sessionClosed,
                    a: DiagnosticTransportKind.iroh.rawValue,
                    b: exit.failure == .none ? nil : exit.failure.rawValue,
                    c: diagnosticSessionID
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
            handleRoute: { [weak self] binding, pathHints in
                guard await self?.allowsPersistence(
                    accountID: accountID,
                    revision: revision
                ) == true else { return }
                await self?.recordActiveRoute(
                    binding,
                    pathHints: pathHints,
                    accountID: accountID,
                    tag: tag,
                    revision: revision
                )
            },
            handleDeactivation: { [weak self] _ in
                await self?.handleActiveRuntimeDeactivation(
                    revision: revision,
                    stopLANPublication: {
                        await lanPublisher.stop()
                    },
                    clearHostRuntime: {
                        // The runtime owns the local Mac binding, while admitted
                        // sessions carry remote iOS binding IDs. Endpoint teardown
                        // therefore closes every Iroh-authorized connection and
                        // leaves Tailscale/other private-network sessions intact.
                        MobileHostService.shared.closeAllIrohConnections()
                    }
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
            clearIrohRoutePublication(revision: revision)
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
        _ = publishIrohRouteIfActive(revision: revision)
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
            revision: revision,
            refreshImmediately: relayPolicyNeedsImmediateRefresh
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
        guard allowsPersistence(
            accountID: accountID,
            revision: revision
        ) else { return }
        lastKnownBindingID = binding.bindingID
        lastKnownAccountID = accountID
        lastKnownTag = tag
        if preparedSignOut?.pendingRevocation?.accountID == accountID {
            preparedSignOut = nil
        }
    }

    private func recordActiveRoute(
        _ binding: CmxIrohBrokerBindingMetadata,
        pathHints: [CmxIrohPathHint],
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
        stageIrohRoute(binding, pathHints: pathHints, revision: revision)
        if runtime != nil, activeAccountID == accountID {
            _ = publishIrohRouteIfActive(revision: revision)
        }
    }

    /// Starts a new availability generation. Persisted broker identity is not
    /// a dialable route until the matching endpoint reports active.
    func beginIrohRouteActivation(revision: UInt64) {
        guard revision == lifecycleRevision else { return }
        pendingIrohRouteBinding = nil
        routePublicationPhase = .starting(revision: revision)
        MobileHostService.shared.updateIrohRoute(identity: nil)
    }

    func stageIrohRoute(
        _ binding: CmxIrohBrokerBindingMetadata,
        pathHints: [CmxIrohPathHint],
        revision: UInt64
    ) {
        guard revision == lifecycleRevision else { return }
        pendingIrohRouteBinding = (
            revision: revision,
            binding: binding,
            pathHints: pathHints
        )
    }

    /// Publishes only the binding staged by the activation generation whose
    /// endpoint has completed `start()`.
    @discardableResult
    func publishIrohRouteIfActive(revision: UInt64) -> Bool {
        guard revision == lifecycleRevision,
              let pendingIrohRouteBinding,
              pendingIrohRouteBinding.revision == revision else { return false }
        self.pendingIrohRouteBinding = nil
        routePublicationPhase = .active(
            revision: revision,
            binding: pendingIrohRouteBinding.binding
        )
        MobileHostService.shared.updateIrohRoute(
            identity: pendingIrohRouteBinding.binding.endpointID,
            pathHints: pendingIrohRouteBinding.pathHints
        )
        return true
    }

    func clearIrohRoutePublication(revision: UInt64? = nil) {
        if let revision, revision != lifecycleRevision { return }
        pendingIrohRouteBinding = nil
        routePublicationPhase = .unavailable
        MobileHostService.shared.updateIrohRoute(identity: nil)
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

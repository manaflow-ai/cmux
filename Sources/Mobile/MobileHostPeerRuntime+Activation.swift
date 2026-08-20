import CMUXMobileCore
import CmuxAuthRuntime
import CmuxPeerTransport
import CmuxPeerTransportCore
import Foundation
import os

private let mobileHostRelayLog = Logger(
    subsystem: "dev.cmux",
    category: "mobile-host-relay"
)

/// Executes relay rotation steps against the live endpoint manager. The
/// home-relay probe is a bounded, cancellable poll because iroh-ffi v1.1.0
/// exposes home-relay state as an on-demand read only.
struct MobileHostPeerRelayApplier: PeerRelayApplying {
    let manager: PeerEndpointManager

    func insertRelay(_ config: PeerRelayConfig) async throws {
        try await manager.applyRelays(
            insert: [PeerRelayEndpointConfig(url: config.url, authToken: config.authToken)],
            remove: []
        )
    }

    func removeRelay(url: String) async throws {
        try await manager.applyRelays(insert: [], remove: [url])
    }

    func homeRelayHealthy() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if await manager.homeRelayStatus().isConnected { return }
            try await clock.sleep(for: .milliseconds(250))
        }
        throw MobileHostPeerRuntimeError.homeRelayUnhealthy
    }

    func execute(_ steps: [PeerRelayRotationStep]) async throws {
        for step in steps {
            switch step {
            case let .insertRelay(config):
                try await insertRelay(config)
            case let .removeRelay(url):
                try await removeRelay(url: url)
            case .awaitHomeRelayHealthy:
                try await homeRelayHealthy()
            }
        }
    }
}

extension MobileHostPeerRuntime {
    // MARK: - Activation

    func activate(accountID: String, revision: UInt64) async throws {
        beginRouteActivation(revision: revision)
        guard let auth else { throw MobileHostPeerRuntimeError.inactive }
        // Pin the runtime's broker to the session identity that owns
        // `accountID`: every broker request below re-reads an ATOMIC
        // authenticated snapshot validated against this pin, so an A→B account
        // switch makes the old runtime's requests fail closed immediately.
        guard auth.currentUser?.id == accountID else {
            throw MobileHostPeerRuntimeError.inactive
        }
        let tag = Self.currentTag()
        guard let clientNamespace = Self.macClientNamespace(
            bundleIdentifier: Bundle.main.bundleIdentifier
        ) else {
            throw MobileHostPeerRuntimeError.invalidLocalBinding
        }
        // Account-scoped broker cooldown outlives runtime teardown; while it
        // is active, activation skips broker work entirely and the failure
        // rebuilder surfaces the floor to the reconnect schedule.
        if await brokerCooldowns.activeCooldown(
            key: PeerBrokerCooldownLedger.Key(accountID: accountID)
        ) != nil {
            throw MobileHostPeerRuntimeError.brokerCooldownActive
        }
        let appInstanceID = try appInstances.appInstanceID(
            accountID: accountID,
            tag: tag
        )
        let identity = try await identities.identity(
            accountID: accountID,
            appInstanceID: appInstanceID
        )
        let deviceID = cmxCanonicalDeviceID(MobileHostIdentity.deviceID())
        let endpointID = identity.endpointID
        lastKnownAccountID = accountID
        lastKnownTag = tag

        guard let brokerBaseURL = AuthEnvironment.irohBrokerBaseURL else {
            throw MobileHostPeerRuntimeError.invalidBrokerBaseURL
        }
        let broker = try PeerTrustBrokerClient(
            baseURL: brokerBaseURL,
            tokenProvider: Self.accountPinnedTokenProvider(
                auth: auth,
                accountID: accountID
            ),
            clientNamespace: clientNamespace,
            discoveryScope: PeerDiscoveryScope(
                deviceID: deviceID,
                appInstanceID: appInstanceID,
                tag: tag,
                platform: .mac,
                peerPlatform: .ios
            )
        )

        let mode = transportVerificationMode
        var relayConfigs: [PeerRelayConfig] = []
        var relayPlan: PeerRelayCredentialPlan?
        var relayPolicy: PeerRelayPolicy?
        var relayPolicySource: CmxIrohSettingsSnapshot.PolicySource = .unavailable

        // Broker registration: challenge + signed payload, scoped discovery.
        let signer = try PeerRegistrationSigner(
            identity: identity,
            endpointID: endpointID.endpointID
        )
        let payload = try PeerRegistrationPayload(
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            clientNamespace: clientNamespace,
            tag: tag,
            platform: .mac,
            displayName: MobileHostIdentity.instanceDisplayName(),
            endpointID: endpointID.endpointID,
            identityGeneration: identity.generation,
            pairingEnabled: true,
            capabilities: Self.capabilities,
            pathHints: []
        )
        let prepared = try signer.prepare(payload: payload)
        let registration: PeerBrokerRegistrationResponse
        do {
            registration = try await broker.register(
                prepared: prepared,
                signer: signer
            )
        } catch {
            noteBrokerRateLimit(error, accountID: accountID)
            throw error
        }
        await brokerCooldowns.clear(
            key: PeerBrokerCooldownLedger.Key(accountID: accountID)
        )
        guard let discovery = registration.discovery else {
            throw MobileHostPeerRuntimeError.registrationIncomplete
        }

        // Relay policy resolve (fail-closed) + relay JWT mint. Minting must
        // follow registration: the broker attaches the binding request proof
        // that register() just retained, and the mint endpoint rejects
        // proof-less non-legacy requests. A missing, expired, or rolled-back
        // cached policy yields direct-only relays; relay credentials are
        // minted only against a verified policy.
        if mode != .directOnly, let relayPolicyTrustRoot {
            let resolution = await relayPolicyCache.resolve(
                trustRoot: relayPolicyTrustRoot,
                now: Date()
            )
            if case let .verified(policy) = resolution {
                relayPolicy = policy
                relayPolicySource = .cached
            }
            diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshStarted))
            do {
                let minted = try await broker.relayToken(endpointID: endpointID)
                // A fresh install has no cached policy; the mint response
                // bundles the current signed policy, which installs through
                // the same verify + rollback-guarded cache path.
                if relayPolicy == nil, let signedPolicy = minted.signedPolicy {
                    relayPolicy = try await relayPolicyCache.install(
                        signedPolicy: signedPolicy,
                        trustRoot: relayPolicyTrustRoot,
                        now: Date()
                    )
                    relayPolicySource = .server
                }
                guard let policy = relayPolicy else {
                    throw PeerRelayPolicyError.invalidToken
                }
                let plan = try PeerRelayCredentialPlan(
                    policy: policy,
                    minted: Self.relayTokenResponse(minted),
                    now: Date()
                )
                relayConfigs = plan.configs
                relayPlan = plan
                diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshSucceeded))
            } catch {
                // Credential mint failure keeps the endpoint direct-only;
                // the refresh loop below retries against the same policy.
                noteBrokerRateLimit(error, accountID: accountID)
                #if DEBUG
                mobileHostRelayLog.error(
                    "relay credential mint failed at activation: \(String(describing: error), privacy: .public)"
                )
                #endif
                diagnosticLog.record(DiagnosticEvent(
                    .relayPolicyRefreshFailed,
                    b: Self.diagnosticFailureKind(for: error).rawValue
                ))
            }
        }

        guard revision == lifecycleRevision, !Task.isCancelled else {
            throw CancellationError()
        }

        // Endpoint activation from the account-scoped secret. A settings
        // rebind re-runs this with the same key, so the EndpointID is stable.
        let generation = try await endpointManager.activate(
            secretKey: identity.secretKey.bytes,
            relays: relayConfigs.map {
                PeerRelayEndpointConfig(url: $0.url, authToken: $0.authToken)
            },
            directOnly: mode == .directOnly
        )

        // One admission controller per activation: local grant verification
        // against the discovery key set, plus a bounded broker discover()
        // revalidation. A valid online denial is sticky; only connectivity
        // failure lets a locally valid grant continue offline.
        let admission = Self.makeAdmissionController(
            broker: broker,
            grantKeys: discovery.grantVerificationKeys,
            localBinding: registration.binding
        )
        let acceptor = PeerHostSessionAcceptor()
        let listener = PeerInboundListener(
            manager: endpointManager,
            handler: Self.makeConnectionHandler(
                runtime: self,
                acceptor: acceptor,
                admission: admission,
                revision: revision,
                generation: generation
            )
        )
        try await listener.start(generation: generation)

        guard revision == lifecycleRevision,
              !Task.isCancelled,
              !signOutIntentActive,
              desiredActive,
              observedAccountID == accountID else {
            await listener.stop()
            await endpointManager.deactivate()
            throw CancellationError()
        }

        let activeRuntime = MobileHostPeerActiveRuntime(
            accountID: accountID,
            revision: revision,
            tag: tag,
            clientNamespace: clientNamespace,
            broker: broker,
            binding: registration.binding,
            identity: identity,
            admission: admission,
            listener: listener,
            generation: generation,
            appliedRelayConfigs: relayConfigs,
            relayPolicySource: relayPolicySource,
            relayPolicySequence: relayPolicy?.sequence,
            relayPolicyExpiresAt: relayPolicy.map {
                Date(timeIntervalSince1970: TimeInterval($0.expiresAt))
            }
        )
        active = activeRuntime
        activeAccountID = accountID
        stageRoute(registration.binding, revision: revision)
        publishRouteIfActive(revision: revision)
        diagnosticLog.record(DiagnosticEvent(
            .endpointActive,
            a: DiagnosticTransportKind.iroh.rawValue
        ))

        startEndpointHealthWatchdog(for: activeRuntime)
        scheduleRelayCredentialRefresh(
            for: activeRuntime,
            plan: relayPlan
        )
        publishIrohSettingsUpdate()
        if preparedSignOut?.accountID == accountID {
            preparedSignOut = nil
        }
    }

    /// An ATOMIC authenticated snapshot per fetch, validated against the
    /// activation's ACCOUNT pin: an account switch completing while the read
    /// is suspended can never hand this runtime a different account's
    /// credentials. Deliberately NOT generation-pinned: a same-account
    /// re-sign-in must keep this long-lived runtime serviceable.
    static func accountPinnedTokenProvider(
        auth: AuthCoordinator,
        accountID: String
    ) -> PeerBrokerTokenProvider {
        PeerBrokerTokenProvider(
            capture: { @MainActor [weak auth] in
                guard let auth else { return nil }
                let session: AuthenticatedSessionSnapshot
                do {
                    session = try await auth.authenticatedSessionSnapshot()
                } catch AuthError.unauthorized {
                    // Definitively signed out: fail closed.
                    return nil
                }
                // Transient failures (a revalidation owns the token store, a
                // re-mint is in flight or offline) rethrow so the broker
                // classifies them as connectivity instead of tearing the host
                // runtime down as unauthorized.
                guard session.accountID == accountID else { return nil }
                return PeerBrokerCredentials(
                    accessToken: session.accessToken,
                    refreshToken: session.refreshToken
                )
            },
            forceRefresh: { @MainActor [weak auth] in
                guard let auth else { return }
                _ = try await auth.forceRefreshAccessToken()
            }
        )
    }

    /// Maps the broker relay-token wire response onto the relay module's
    /// credential model consumed by `PeerRelayCredentialPlan`.
    nonisolated static func relayTokenResponse(
        _ minted: PeerBrokerRelayTokenResponse
    ) -> PeerRelayTokenResponse {
        PeerRelayTokenResponse(
            credentials: minted.credentials.map { credential in
                PeerRelayCredential(
                    relayURL: credential.relayURL,
                    token: credential.token,
                    expiresAt: credential.expiresAt,
                    refreshAfter: credential.refreshAfter
                )
            }
        )
    }

    func noteBrokerRateLimit(_ error: any Error, accountID: String) {
        guard let brokerError = error as? PeerBrokerError,
              case let .serverRateLimited(retryAfter) = brokerError else {
            return
        }
        let cooldowns = brokerCooldowns
        Task {
            await cooldowns.noteRetryAfter(
                retryAfter,
                key: PeerBrokerCooldownLedger.Key(accountID: accountID)
            )
        }
    }

    // MARK: - Admission

    /// verifyGrant checks signature, claim shape, expiry, platform direction,
    /// and this Mac's exact local binding; the admission controller then binds
    /// the grant to the TLS-proven initiator endpoint and consults the broker.
    nonisolated static func makeAdmissionController(
        broker: PeerTrustBrokerClient,
        grantKeys: PeerGrantVerificationKeySet,
        localBinding: PeerBrokerBinding
    ) -> PeerAdmissionController {
        let verifier = PeerGrantVerifier()
        let acceptor = PeerGrantPeer(binding: localBinding)
        let localBindingID = localBinding.bindingID
        return PeerAdmissionController(
            verifyGrant: { token in
                // The public verifier requires the exact initiator tuple; the
                // token itself carries it, and the admission controller
                // separately binds the verified initiator EndpointID to the
                // TLS-authenticated connection. Decoding the unverified tuple
                // first therefore grants nothing by itself.
                let claims = try verifier.verifyPairGrant(
                    token,
                    keys: grantKeys,
                    initiator: Self.unverifiedInitiator(of: token),
                    acceptor: acceptor,
                    now: Date()
                )
                return PeerVerifiedGrant(
                    grantID: claims.grantID,
                    initiatorDeviceID: claims.initiator.deviceID,
                    acceptorDeviceID: claims.acceptor.deviceID,
                    initiatorEndpointID: claims.initiator.endpointID.endpointID,
                    expiresAt: Date(
                        timeIntervalSince1970: TimeInterval(claims.expiresAt)
                    )
                )
            },
            brokerVerdict: { grant in
                do {
                    let snapshot = try await broker.discover()
                    let initiatorMatches = snapshot.bindings.filter { binding in
                        binding.platform == .ios
                            && binding.deviceID == grant.initiatorDeviceID
                            && binding.endpointID.endpointID.lowercased()
                                == grant.initiatorEndpointID.lowercased()
                            && binding.pairingEnabled
                    }
                    let acceptorMatches = snapshot.bindings.filter { binding in
                        binding.bindingID == localBindingID && binding.pairingEnabled
                    }
                    guard initiatorMatches.count == 1,
                          acceptorMatches.count == 1 else {
                        return .denied("binding-mismatch")
                    }
                    return .admitted
                } catch let error as PeerBrokerError {
                    switch error {
                    case .connectivity, .serverRateLimited:
                        return .unreachable
                    case .unauthorized, .denied, .protocolError:
                        return .denied("broker-rejected")
                    }
                } catch {
                    return .unreachable
                }
            }
        )
    }

    private struct UnverifiedGrantEnvelope: Decodable {
        let initiator: PeerGrantPeer
    }

    /// Decodes the initiator tuple from an UNVERIFIED grant token. Used only
    /// to feed the verifier's exact-match API; every security property is
    /// enforced by the verifier's signature/claims checks plus the admission
    /// controller's TLS endpoint binding.
    nonisolated static func unverifiedInitiator(of token: String) throws -> PeerGrantPeer {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            throw PeerGrantVerifierError.invalidToken
        }
        var encoded = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.utf8.count % 4
        if remainder != 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let payload = Data(base64Encoded: encoded),
              let envelope = try? JSONDecoder().decode(
                  UnverifiedGrantEnvelope.self,
                  from: payload
              ) else {
            throw PeerGrantVerifierError.invalidClaims
        }
        return envelope.initiator
    }

    // MARK: - Endpoint health

    /// Watchdog for upstream iroh#4289 (driver death after failed rebind):
    /// recreate from the same secret key, restart the listener on the new
    /// runtime generation, and treat a failed recreate as a terminal failure.
    func startEndpointHealthWatchdog(for runtime: MobileHostPeerActiveRuntime) {
        let manager = endpointManager
        let revision = runtime.revision
        let watchdog = PeerEndpointHealthWatchdog(
            interval: .seconds(30),
            probe: { await manager.probeHealth() },
            recreate: { [weak self] reason in
                await self?.recoverEndpoint(reason: reason, revision: revision)
            }
        )
        runtime.watchdog = watchdog
        Task { await watchdog.start() }
    }

    func recoverEndpoint(reason: String, revision: UInt64) async {
        guard revision == lifecycleRevision,
              let active, active.revision == revision else { return }
        mobileHostPeerLog.error(
            "Peer endpoint died (\(reason, privacy: .public)); recreating in place"
        )
        do {
            let generation = try await endpointManager.recreate()
            guard self.active === active,
                  revision == lifecycleRevision else { return }
            active.generation = generation
            await active.listener.stop()
            try await active.listener.start(generation: generation)
        } catch {
            await noteRuntimeFailure(error, revision: revision)
        }
    }

    // MARK: - Relay credential refresh

    /// Refreshes the endpoint-bound relay JWTs before expiry by executing a
    /// make-before-break rotation plan against the live endpoint. A policy
    /// that can no longer be verified fails closed to direct-only. Mint
    /// failures retry on the host backoff ladder bounded by credential expiry.
    func scheduleRelayCredentialRefresh(
        for runtime: MobileHostPeerActiveRuntime,
        plan initialPlan: PeerRelayCredentialPlan?
    ) {
        runtime.relayRefreshTask?.cancel()
        guard let relayPolicyTrustRoot else { return }
        // A nil plan means the activation-time mint failed (or returned no
        // usable policy); the loop below still runs so the backoff ladder can
        // mint the bootstrap credentials instead of leaving the endpoint
        // direct-only until the next full activation.
        let manager = endpointManager
        let cache = relayPolicyCache
        let revision = runtime.revision
        runtime.relayRefreshTask = Task { @MainActor [weak self] in
            var plan = initialPlan
            var backoff = PeerReconnectBackoff(profile: .host)
            let clock = ContinuousClock()
            if plan != nil {
                await self?.publishRelayPathHints(for: runtime)
            }
            while !Task.isCancelled {
                guard let self, self.active === runtime,
                      revision == self.lifecycleRevision else { return }
                let now = Date()
                let sleepSeconds: TimeInterval
                if let schedule = plan?.schedule {
                    sleepSeconds = max(0, schedule.refreshDeadline.timeIntervalSince(now))
                } else {
                    // No live credentials: retry minting on the backoff ladder.
                    let delay = backoff.nextDelay()
                    sleepSeconds = TimeInterval(delay.components.seconds)
                }
                if sleepSeconds > 0 {
                    do {
                        try await clock.sleep(for: .seconds(sleepSeconds))
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled, self.active === runtime,
                      revision == self.lifecycleRevision else { return }
                self.diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshStarted))
                let resolution = await cache.resolve(
                    trustRoot: relayPolicyTrustRoot,
                    now: Date()
                )
                var verifiedPolicy: PeerRelayPolicy?
                var policySource = CmxIrohSettingsSnapshot.PolicySource.cached
                if case let .verified(policy) = resolution {
                    verifiedPolicy = policy
                }
                do {
                    let minted = try await runtime.broker.relayToken(
                        endpointID: runtime.identity.endpointID
                    )
                    // An empty or unverifiable cache recovers here: the mint
                    // response bundles the current signed policy, installed
                    // through the same verify + rollback-guarded cache path.
                    if verifiedPolicy == nil, let signedPolicy = minted.signedPolicy {
                        verifiedPolicy = try? await cache.install(
                            signedPolicy: signedPolicy,
                            trustRoot: relayPolicyTrustRoot,
                            now: Date()
                        )
                        policySource = .server
                    }
                    guard let policy = verifiedPolicy else {
                        // Fail closed: remove every applied relay, keep direct
                        // paths and admitted sessions intact.
                        let removal = PeerRelayRotationPlanner().plan(
                            applied: runtime.appliedRelayConfigs,
                            refreshed: [],
                            generation: runtime.generation
                        )
                        let applier = MobileHostPeerRelayApplier(manager: manager)
                        try? await applier.execute(
                            removal.steps(ifCurrent: runtime.generation) ?? []
                        )
                        runtime.appliedRelayConfigs = []
                        runtime.relayPolicySource = .unavailable
                        runtime.relayPolicySequence = nil
                        runtime.relayPolicyExpiresAt = nil
                        plan = nil
                        self.diagnosticLog.record(DiagnosticEvent(
                            .relayPolicyRefreshFailed,
                            b: DiagnosticFailureKind.policyUnavailable.rawValue
                        ))
                        self.publishIrohSettingsUpdate()
                        continue
                    }
                    let refreshed = try PeerRelayCredentialPlan(
                        policy: policy,
                        minted: Self.relayTokenResponse(minted),
                        now: Date()
                    )
                    let rotation = PeerRelayRotationPlanner().plan(
                        applied: runtime.appliedRelayConfigs,
                        refreshed: refreshed.configs,
                        generation: runtime.generation
                    )
                    if let steps = rotation.steps(ifCurrent: runtime.generation),
                       !steps.isEmpty {
                        let applier = MobileHostPeerRelayApplier(manager: manager)
                        do {
                            try await applier.execute(steps)
                        } catch {
                            if let rollback = rotation.rollbackSteps(
                                ifCurrent: runtime.generation
                            ) {
                                try? await applier.execute(rollback)
                            }
                            throw error
                        }
                    }
                    runtime.appliedRelayConfigs = refreshed.configs
                    runtime.relayPolicySource = policySource
                    runtime.relayPolicySequence = policy.sequence
                    runtime.relayPolicyExpiresAt = Date(
                        timeIntervalSince1970: TimeInterval(policy.expiresAt)
                    )
                    plan = refreshed
                    backoff.reset()
                    self.diagnosticLog.record(DiagnosticEvent(.relayPolicyRefreshSucceeded))
                    self.publishIrohSettingsUpdate()
                    await self.publishRelayPathHints(for: runtime)
                } catch {
                    self.noteBrokerRateLimit(error, accountID: runtime.accountID)
                    #if DEBUG
                    mobileHostRelayLog.error(
                        "relay credential refresh failed: \(String(describing: error), privacy: .public)"
                    )
                    #endif
                    self.diagnosticLog.record(DiagnosticEvent(
                        .relayPolicyRefreshFailed,
                        b: Self.diagnosticFailureKind(for: error).rawValue
                    ))
                    if let expiresAt = plan?.schedule.expiresAt, Date() >= expiresAt {
                        // Credentials expired with no replacement: fail closed
                        // to direct-only until a later mint succeeds.
                        let removal = PeerRelayRotationPlanner().plan(
                            applied: runtime.appliedRelayConfigs,
                            refreshed: [],
                            generation: runtime.generation
                        )
                        let applier = MobileHostPeerRelayApplier(manager: manager)
                        try? await applier.execute(
                            removal.steps(ifCurrent: runtime.generation) ?? []
                        )
                        runtime.appliedRelayConfigs = []
                        plan = nil
                        self.publishIrohSettingsUpdate()
                    }
                }
            }
        }
    }

    /// Publishes the endpoint's relay path hints through a registration
    /// refresh so dialers can route to this host: upstream `EndpointAddr`
    /// carries a single relay URL, and a binding starts hint-less because
    /// relay credentials are minted only after the first registration.
    /// Broker hints expire within the hour, so every successful credential
    /// refresh republishes them; a failed publication waits for the next
    /// refresh cycle rather than tearing anything down.
    func publishRelayPathHints(for runtime: MobileHostPeerActiveRuntime) async {
        guard active === runtime, !runtime.appliedRelayConfigs.isEmpty else { return }
        // Hint order matters (dialers use the first hint), so wait — bounded —
        // for the home relay connection and lead with it. Hints publish the
        // applied config URL form, not iroh's home-relay string: the broker
        // drops hint values that do not exactly match the managed relay set.
        try? await MobileHostPeerRelayApplier(manager: endpointManager)
            .homeRelayHealthy()
        let homeURLs = await endpointManager.homeRelayStatus().connectedRelayURLs
            .map(Self.looseRelayURLKey)
        let appliedURLs = runtime.appliedRelayConfigs.map(\.url)
        let relayURLs = appliedURLs.filter { homeURLs.contains(Self.looseRelayURLKey($0)) }
            + appliedURLs.filter { !homeURLs.contains(Self.looseRelayURLKey($0)) }
        let now = Date()
        let hints = relayURLs.prefix(2).compactMap { url in
            try? CmxIrohPathHint(
                kind: .relayURL,
                value: url,
                source: .native,
                privacyScope: .publicInternet,
                observedAt: now,
                expiresAt: now.addingTimeInterval(55 * 60)
            )
        }
        guard !hints.isEmpty, active === runtime else { return }
        do {
            let signer = try PeerRegistrationSigner(
                identity: runtime.identity,
                endpointID: runtime.identity.endpointID.endpointID
            )
            let payload = try PeerRegistrationPayload(
                deviceID: cmxCanonicalDeviceID(MobileHostIdentity.deviceID()),
                appInstanceID: appInstances.appInstanceID(
                    accountID: runtime.accountID,
                    tag: runtime.tag
                ),
                clientNamespace: runtime.clientNamespace,
                tag: runtime.tag,
                platform: .mac,
                displayName: MobileHostIdentity.instanceDisplayName(),
                endpointID: runtime.identity.endpointID.endpointID,
                identityGeneration: runtime.identity.generation,
                pairingEnabled: true,
                capabilities: Self.capabilities,
                pathHints: hints
            )
            let prepared = try signer.prepare(payload: payload)
            let registration = try await runtime.broker.register(
                prepared: prepared,
                signer: signer
            )
            guard active === runtime else { return }
            stageRoute(registration.binding, revision: runtime.revision)
            publishRouteIfActive(revision: runtime.revision)
        } catch {
            #if DEBUG
            mobileHostRelayLog.error(
                "relay path hint publication failed: \(String(describing: error), privacy: .public)"
            )
            #endif
        }
    }

    /// Equality key for matching iroh's home-relay URL string against the
    /// canonical managed relay origin (case and trailing-slash insensitive).
    private static func looseRelayURLKey(_ value: String) -> String {
        var key = value.lowercased()
        while key.hasSuffix("/") {
            key.removeLast()
        }
        return key
    }
}

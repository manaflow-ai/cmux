public import CMUXMobileCore
public import Foundation

/// Resolves fresh same-account reachability and a locally verified pair grant per dial.
public actor CmxIrohRegistryContextProvider: CmxIrohClientContextProvider {
    private struct VerifiedDiscoverySnapshot: Sendable {
        let response: CmxIrohDiscoveryResponse
        let verifiedAt: Date
    }

    private static let maximumVerifiedDiscoveryReuseAge: TimeInterval = 30

    public typealias LANFallbackProvider = @Sendable (
        _ target: CmxIrohBrokerBindingMetadata,
        _ authenticatedBindings: [CmxIrohBrokerBindingMetadata],
        _ rendezvous: CmxIrohLANRendezvous
    ) async -> [CmxIrohPathHint]
    public typealias CustomPrivateFallbackProvider = @Sendable (
        _ expectedMacDeviceID: String
    ) async -> [CmxIrohCustomPrivatePathBootstrap]

    let supervisor: CmxIrohEndpointSupervisor
    let broker: any CmxIrohRegistryServing
    var localBindingExpectation: CmxIrohLocalBindingExpectation
    var managedRelayURLs: Set<String>
    var allowedRouteRelayURLs: Set<String>
    let networkPathSnapshot: (@Sendable () async throws -> CmxIrohNetworkPathSnapshot)?
    var offlinePolicy: CmxIrohClientOfflinePolicyContext?
    let lanFallback: LANFallbackProvider?
    let customPrivateFallback: CustomPrivateFallbackProvider?
    let verifier: CmxIrohGrantVerifier
    let now: @Sendable () -> Date
    var grantCache: [CmxIrohPeerIdentity: CmxIrohRegistryGrantCache] = [:]
    var pairGrantRetryDeadline: (code: String?, date: Date)?
    var lanAuthorities: [CmxIrohPeerIdentity: CmxIrohRegistryLANAuthority] = [:]
    private var verifiedDiscoverySnapshot: VerifiedDiscoverySnapshot?

    /// Creates a public-route provider from the generation-less seam.
    public init(
        supervisor: CmxIrohEndpointSupervisor,
        broker: any CmxIrohRegistryServing,
        localBindingExpectation: CmxIrohLocalBindingExpectation,
        managedRelayURLs: Set<String>,
        allowedRouteRelayURLs: Set<String>? = nil,
        activeNetworkProfiles: @escaping @Sendable () async -> Set<CmxIrohNetworkProfileKey>,
        offlinePolicy: CmxIrohClientOfflinePolicyContext? = nil,
        lanFallback: LANFallbackProvider? = nil,
        customPrivateFallback: CustomPrivateFallbackProvider? = nil,
        verifiedDiscovery: CmxIrohDiscoveryResponse? = nil,
        verifier: CmxIrohGrantVerifier = CmxIrohGrantVerifier(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.supervisor = supervisor
        self.broker = broker
        self.localBindingExpectation = localBindingExpectation
        self.managedRelayURLs = managedRelayURLs
        self.allowedRouteRelayURLs = allowedRouteRelayURLs ?? managedRelayURLs
        _ = activeNetworkProfiles
        networkPathSnapshot = nil
        self.offlinePolicy = offlinePolicy
        self.lanFallback = lanFallback
        self.customPrivateFallback = customPrivateFallback
        self.verifier = verifier
        self.now = now
        verifiedDiscoverySnapshot = verifiedDiscovery.map {
            VerifiedDiscoverySnapshot(response: $0, verifiedAt: now())
        }
    }

    /// Creates a provider with generation-aware private-network validation.
    public init(
        supervisor: CmxIrohEndpointSupervisor,
        broker: any CmxIrohRegistryServing,
        localBindingExpectation: CmxIrohLocalBindingExpectation,
        managedRelayURLs: Set<String>,
        allowedRouteRelayURLs: Set<String>? = nil,
        networkPathSnapshot: @escaping @Sendable () async throws -> CmxIrohNetworkPathSnapshot,
        offlinePolicy: CmxIrohClientOfflinePolicyContext? = nil,
        lanFallback: LANFallbackProvider? = nil,
        customPrivateFallback: CustomPrivateFallbackProvider? = nil,
        verifiedDiscovery: CmxIrohDiscoveryResponse? = nil,
        verifier: CmxIrohGrantVerifier = CmxIrohGrantVerifier(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.supervisor = supervisor
        self.broker = broker
        self.localBindingExpectation = localBindingExpectation
        self.managedRelayURLs = managedRelayURLs
        self.allowedRouteRelayURLs = allowedRouteRelayURLs ?? managedRelayURLs
        self.networkPathSnapshot = networkPathSnapshot
        self.offlinePolicy = offlinePolicy
        self.lanFallback = lanFallback
        self.customPrivateFallback = customPrivateFallback
        self.verifier = verifier
        self.now = now
        verifiedDiscoverySnapshot = verifiedDiscovery.map {
            VerifiedDiscoverySnapshot(response: $0, verifiedAt: now())
        }
    }

    public func context(
        for request: CmxByteTransportRequest
    ) async throws -> CmxIrohClientContext {
        let route = request.route
        guard route.kind == .iroh,
              request.authorizationMode == .transportAdmission,
              case let .peer(targetIdentity, routeHints) = route.endpoint else {
            throw CmxIrohRegistryContextError.unsupportedRoute
        }
        lanAuthorities.removeValue(forKey: targetIdentity)
        let endpoint = try await supervisor.activeEndpoint()
        let localIdentity = await endpoint.identity()
        guard localBindingExpectation.platform == .ios,
              localBindingExpectation.endpointID == localIdentity else {
            throw CmxIrohRegistryContextError.localBindingUnavailable
        }
        let clock = now()
        let discovery: CmxIrohDiscoveryResponse
        if let verified = takeVerifiedDiscovery(at: clock) {
            discovery = verified
        } else {
            do {
                discovery = try await broker.discover()
            } catch {
                guard Self.isConnectivity(error),
                      let cached = try await cachedPolicy(
                          for: request,
                          confirmedDiscovery: nil,
                          at: clock
                      ) else {
                    throw error
                }
                rememberCachedLANAuthority(cached)
                return try await context(
                    targetBinding: cached.targetBinding,
                    routeHints: routeHints,
                    pairGrantToken: cached.pairGrant.grant,
                    at: clock
                )
            }
        }
        guard discovery.routeContractVersion == 1 else {
            throw CmxIrohRegistryContextError.incompatibleContract
        }
        guard Set(discovery.relayFleet) == managedRelayURLs else {
            throw CmxIrohRegistryContextError.relayFleetMismatch
        }
        lanAuthorities.removeAll(keepingCapacity: false)
        let localMatches = discovery.bindings.filter {
            localBindingExpectation.matches($0)
        }
        guard localMatches.count == 1, let localBinding = localMatches.first else {
            throw CmxIrohRegistryContextError.localBindingUnavailable
        }
        let targetMatches = discovery.bindings.filter {
            $0.endpointID == targetIdentity && $0.platform == .mac
        }
        guard targetMatches.count == 1, let targetBinding = targetMatches.first else {
            throw CmxIrohRegistryContextError.targetBindingUnavailable
        }
        guard let expectedPeerDeviceID = request.expectedPeerDeviceID,
              CmxIrohDeviceID(expectedPeerDeviceID)
                == CmxIrohDeviceID(targetBinding.deviceID) else {
            throw CmxIrohRegistryContextError.targetDeviceMismatch
        }
        guard targetBinding.pairingEnabled else {
            throw CmxIrohRegistryContextError.targetNotPairable
        }
        replaceLANAuthorities(with: discovery)
        let initiator = CmxIrohGrantPeer(binding: localBinding)
        let acceptor = CmxIrohGrantPeer(binding: targetBinding)
        let pairGrant: CmxIrohPairGrantResponse
        do {
            pairGrant = try await grant(
                initiator: initiator,
                acceptor: acceptor,
                targetIdentity: targetIdentity,
                keys: discovery.grantVerificationKeys,
                now: clock
            )
        } catch {
            guard Self.isConnectivity(error),
                  let cached = try await cachedPolicy(
                      for: request,
                      confirmedDiscovery: discovery,
                      at: clock
                  ) else {
                throw error
            }
            rememberCachedLANAuthority(cached, bindings: discovery.bindings)
            return try await context(
                targetBinding: cached.targetBinding,
                routeHints: routeHints,
                pairGrantToken: cached.pairGrant.grant,
                at: clock
            )
        }
        if let offlinePolicy {
            try? await offlinePolicy.cache.save(
                localBinding: localBinding,
                targetBinding: targetBinding,
                discovery: discovery,
                pairGrant: pairGrant,
                for: offlinePolicy.expectation,
                now: clock
            )
        }
        return try await context(
            targetBinding: targetBinding,
            routeHints: routeHints,
            pairGrantToken: pairGrant.grant,
            at: clock
        )
    }

    /// Replaces broker-verified route policy without replacing this provider's
    /// grant cache or server retry deadline. Runtime registration refreshes are
    /// frequent, while pair grants remain valid for days and broker rate limits
    /// apply across those refresh generations.
    func updatePolicy(
        localBindingExpectation: CmxIrohLocalBindingExpectation,
        managedRelayURLs: Set<String>,
        allowedRouteRelayURLs: Set<String>,
        offlinePolicy: CmxIrohClientOfflinePolicyContext?,
        verifiedDiscovery: CmxIrohDiscoveryResponse? = nil
    ) {
        if self.localBindingExpectation != localBindingExpectation {
            grantCache.removeAll(keepingCapacity: false)
            lanAuthorities.removeAll(keepingCapacity: false)
            verifiedDiscoverySnapshot = nil
        }
        self.localBindingExpectation = localBindingExpectation
        self.managedRelayURLs = managedRelayURLs
        self.allowedRouteRelayURLs = allowedRouteRelayURLs
        self.offlinePolicy = offlinePolicy
        if let verifiedDiscovery {
            verifiedDiscoverySnapshot = VerifiedDiscoverySnapshot(
                response: verifiedDiscovery,
                verifiedAt: now()
            )
        }
    }

    /// Consumes the startup or refresh response once, preventing an immediate
    /// duplicate broker lookup while bounding the revocation visibility delay.
    private func takeVerifiedDiscovery(at clock: Date) -> CmxIrohDiscoveryResponse? {
        guard let snapshot = verifiedDiscoverySnapshot else { return nil }
        verifiedDiscoverySnapshot = nil
        let age = clock.timeIntervalSince(snapshot.verifiedAt)
        guard age >= 0, age <= Self.maximumVerifiedDiscoveryReuseAge else {
            return nil
        }
        return snapshot.response
    }

    private func context(
        targetBinding: CmxIrohBrokerBinding,
        routeHints: [CmxIrohPathHint],
        pairGrantToken: String,
        at clock: Date
    ) async throws -> CmxIrohClientContext {
        let targetIdentity = targetBinding.endpointID
        var routeHints = authoritativePrivateRouteHints(
            routeHints,
            targetBinding: targetBinding,
            at: clock
        )
        routeHints.append(contentsOf: await customPrivateRouteHints(
            targetBinding: targetBinding,
            at: clock
        ))
        let pathSnapshot = try await availableNetworkPathSnapshot(
            for: targetBinding.pathHints + routeHints,
            at: clock
        )
        let profiles = pathSnapshot?.activeNetworkProfiles ?? []
        let hints = CmxIrohRegistryPathMerger.merge(
            primary: targetBinding.pathHints,
            fallback: routeHints,
            at: clock,
            managedRelayURLs: allowedRouteRelayURLs,
            activeNetworkProfiles: profiles
        )
        let endpointAddress = CmxAttachEndpoint.peer(
            identity: targetIdentity,
            pathHints: hints
        )
        guard let dialPlan = endpointAddress.irohDialPlan(
            at: clock,
            managedRelayURLs: allowedRouteRelayURLs,
            activeNetworkProfiles: profiles
        ) else {
            throw CmxIrohRegistryContextError.dialPlanUnavailable
        }
        let fallbackAuthorization: CmxIrohPrivateFallbackAuthorization?
        if let pathSnapshot, !dialPlan.privateFallbackPaths.isEmpty {
            fallbackAuthorization = try CmxIrohPrivateFallbackAuthorization(
                networkPathSnapshot: pathSnapshot,
                pathHints: dialPlan.privateFallbackPaths,
                admittedAt: clock
            )
        } else {
            fallbackAuthorization = nil
        }
        return CmxIrohClientContext(
            dialPlan: dialPlan,
            credential: try .pairGrant(pairGrantToken),
            privateFallbackAuthorization: fallbackAuthorization
        )
    }

    /// Replaces legacy TCP-derived VPN ports with the endpoint-signed Iroh UDP
    /// port for the same address family. Private IPs stay local, while stale or
    /// incomplete broker metadata removes the hint instead of guessing.
    private func authoritativePrivateRouteHints(
        _ hints: [CmxIrohPathHint],
        targetBinding: CmxIrohBrokerBinding,
        at clock: Date
    ) -> [CmxIrohPathHint] {
        let lastSeenAt = CmxIrohISO8601Date.parse(targetBinding.lastSeenAt)
        let portsAreFresh = lastSeenAt.map {
            $0 <= clock.addingTimeInterval(CmxIrohPathHint.maximumObservationClockSkew)
                && $0 >= clock.addingTimeInterval(-CmxIrohPathHint.maximumPrivateHintTTL)
        } ?? false
        let directPorts = portsAreFresh ? targetBinding.directPorts : nil
        return hints.compactMap { hint in
            guard hint.kind == .directAddress,
                  hint.privacyScope != .publicInternet,
                  hint.source == .tailscale || hint.source == .customVPN else {
                return hint
            }
            return directPorts?.replacingPort(in: hint)
        }
    }

    /// Resolves explicit addresses only after broker discovery authenticated
    /// this exact Mac tuple. The broker's current UDP port is authoritative;
    /// the configured address contributes reachability only.
    private func customPrivateRouteHints(
        targetBinding: CmxIrohBrokerBinding,
        at clock: Date
    ) async -> [CmxIrohPathHint] {
        guard let customPrivateFallback,
              let directPorts = freshDirectPorts(
                  targetBinding: targetBinding,
                  at: clock
              ) else { return [] }
        let configured = await customPrivateFallback(targetBinding.deviceID)
        var hints: [CmxIrohPathHint] = []
        for path in configured.prefix(CmxAttachEndpoint.maximumIrohPathHintCount) {
            let port: UInt16?
            switch path.address.family {
            case .ipv4: port = directPorts.ipv4
            case .ipv6: port = directPorts.ipv6
            }
            guard let port,
                  let hint = try? CmxIrohPathHint(
                      kind: .directAddress,
                      value: path.address.socketAddress(port: port),
                      source: .customVPN,
                      privacyScope: .privateNetwork,
                      observedAt: clock,
                      expiresAt: clock.addingTimeInterval(
                          CmxIrohPathHint.maximumPrivateHintTTL
                      ),
                      networkProfile: path.networkProfile
                  ),
                  !hints.contains(hint) else { continue }
            hints.append(hint)
        }
        return hints
    }

    private func freshDirectPorts(
        targetBinding: CmxIrohBrokerBinding,
        at clock: Date
    ) -> CmxIrohDirectPorts? {
        guard let lastSeenAt = CmxIrohISO8601Date.parse(targetBinding.lastSeenAt),
              lastSeenAt <= clock.addingTimeInterval(
                  CmxIrohPathHint.maximumObservationClockSkew
              ),
              lastSeenAt >= clock.addingTimeInterval(
                  -CmxIrohPathHint.maximumPrivateHintTTL
              ) else { return nil }
        return targetBinding.directPorts
    }

    private func cachedPolicy(
        for request: CmxByteTransportRequest,
        confirmedDiscovery: CmxIrohDiscoveryResponse?,
        at clock: Date
    ) async throws -> CmxIrohCachedClientPolicy? {
        guard let offlinePolicy else { return nil }
        return try await offlinePolicy.cache.load(
            for: request,
            localBinding: offlinePolicy.localBinding,
            expectation: offlinePolicy.expectation,
            confirmedDiscovery: confirmedDiscovery,
            now: clock
        )
    }

    public func contextWithPrivateFallback(
        for request: CmxByteTransportRequest,
        basedOn context: CmxIrohClientContext
    ) async throws -> CmxIrohClientContext {
        guard request.route.kind == .iroh,
              request.authorizationMode == .transportAdmission,
              let expectedDeviceID = request.expectedPeerDeviceID,
              case let .peer(targetIdentity, _) = request.route.endpoint,
              let authority = lanAuthorities[targetIdentity],
              authority.target.endpointID == targetIdentity,
              CmxIrohDeviceID(authority.target.deviceID)
                == CmxIrohDeviceID(expectedDeviceID) else {
            return context
        }
        let lanHints = await localFallbackHints(
            target: authority.target,
            bindings: authority.bindings,
            rendezvous: authority.rendezvous
        )
        guard !lanHints.isEmpty else { return context }
        let clock = now()
        let combined = CmxIrohRegistryPathMerger.merge(
            primary: context.dialPlan.publicPaths + context.dialPlan.privateFallbackPaths,
            fallback: lanHints,
            at: clock,
            managedRelayURLs: allowedRouteRelayURLs,
            activeNetworkProfiles: (try await availableNetworkPathSnapshot(
                for: lanHints,
                at: clock
            ))?.activeNetworkProfiles ?? []
        )
        let pathSnapshot = try await availableNetworkPathSnapshot(
            for: combined,
            at: clock
        )
        let profiles = pathSnapshot?.activeNetworkProfiles ?? []
        guard let dialPlan = CmxAttachEndpoint.peer(
            identity: targetIdentity,
            pathHints: combined
        ).irohDialPlan(
            at: clock,
            managedRelayURLs: allowedRouteRelayURLs,
            activeNetworkProfiles: profiles
        ), dialPlan.publicPaths == context.dialPlan.publicPaths else {
            return context
        }
        let authorization: CmxIrohPrivateFallbackAuthorization?
        if let pathSnapshot, !dialPlan.privateFallbackPaths.isEmpty {
            authorization = try CmxIrohPrivateFallbackAuthorization(
                networkPathSnapshot: pathSnapshot,
                pathHints: dialPlan.privateFallbackPaths,
                admittedAt: clock
            )
        } else {
            authorization = nil
        }
        return CmxIrohClientContext(
            dialPlan: dialPlan,
            credential: context.credential,
            privateFallbackAuthorization: authorization
        )
    }

    private func localFallbackHints(
        target: CmxIrohBrokerBinding,
        bindings: [CmxIrohBrokerBinding],
        rendezvous: CmxIrohLANRendezvous
    ) async -> [CmxIrohPathHint] {
        guard let lanFallback else { return [] }
        let result = await lanFallback(
            CmxIrohBrokerBindingMetadata(binding: target),
            bindings.map(CmxIrohBrokerBindingMetadata.init(binding:)),
            rendezvous
        )
        return Array(result.prefix(CmxIrohLANTXTRecord.maximumAddressCount)).filter {
            $0.kind == .directAddress
                && $0.source == .lan
                && $0.privacyScope == .localNetwork
                && $0.networkProfile?.source == .lan
        }
    }

    private func replaceLANAuthorities(with discovery: CmxIrohDiscoveryResponse) {
        var replacement: [CmxIrohPeerIdentity: CmxIrohRegistryLANAuthority] = [:]
        let pairableMacs = discovery.bindings.filter {
            $0.platform == .mac && $0.pairingEnabled
        }
        let counts = Dictionary(grouping: pairableMacs, by: \.endpointID).mapValues(\.count)
        for target in pairableMacs.prefix(CmxIrohDiscoveryResponse.maximumBindingCount)
        where counts[target.endpointID] == 1 {
            replacement[target.endpointID] = CmxIrohRegistryLANAuthority(
                target: target,
                bindings: discovery.bindings,
                rendezvous: discovery.lanRendezvous
            )
        }
        lanAuthorities = replacement
    }

    private func rememberCachedLANAuthority(
        _ policy: CmxIrohCachedClientPolicy,
        bindings: [CmxIrohBrokerBinding]? = nil
    ) {
        guard policy.targetBinding.platform == .mac,
              policy.targetBinding.pairingEnabled else { return }
        lanAuthorities[policy.targetBinding.endpointID] = CmxIrohRegistryLANAuthority(
            target: policy.targetBinding,
            bindings: bindings ?? [policy.targetBinding],
            rendezvous: policy.lanRendezvous
        )
        if lanAuthorities.count > CmxIrohDiscoveryResponse.maximumBindingCount {
            let keep = Set(lanAuthorities.keys.sorted {
                $0.endpointID < $1.endpointID
            }.prefix(CmxIrohDiscoveryResponse.maximumBindingCount))
            lanAuthorities = lanAuthorities.filter { keep.contains($0.key) }
        }
    }

    public func validatePrivateFallback(
        _ authorization: CmxIrohPrivateFallbackAuthorization
    ) async throws {
        guard let networkPathSnapshot else {
            throw CmxIrohPrivateFallbackValidationError.unavailable
        }
        try Task.checkCancellation()
        let clock = now()
        guard authorization.pathHints.allSatisfy({ hint in
            hint.privacyScope != .publicInternet && hint.isUsable(at: clock)
        }) else {
            throw CmxIrohPrivateFallbackValidationError.hintExpiredOrInvalid
        }
        let currentSnapshot: CmxIrohNetworkPathSnapshot
        do {
            currentSnapshot = try await networkPathSnapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CmxIrohPrivateFallbackValidationError.unavailable
        }
        try Task.checkCancellation()
        guard currentSnapshot.generation == authorization.networkPathSnapshot.generation else {
            throw CmxIrohPrivateFallbackValidationError.generationChanged
        }
        guard authorization.pathHints.allSatisfy({ hint in
            guard let profile = hint.networkProfile else { return false }
            return currentSnapshot.activeNetworkProfiles.contains(profile)
        }) else {
            throw CmxIrohPrivateFallbackValidationError.profileUnavailable
        }
    }

    public func invalidateGrant(for identity: CmxIrohPeerIdentity? = nil) {
        if let identity {
            grantCache.removeValue(forKey: identity)
        } else {
            grantCache.removeAll(keepingCapacity: false)
        }
    }

    private func grant(
        initiator: CmxIrohGrantPeer,
        acceptor: CmxIrohGrantPeer,
        targetIdentity: CmxIrohPeerIdentity,
        keys: CmxIrohGrantVerificationKeySet,
        now: Date
    ) async throws -> CmxIrohPairGrantResponse {
        let refreshBoundary = now.addingTimeInterval(72 * 60 * 60)
        if let cached = grantCache[targetIdentity],
           cached.initiator == initiator,
           cached.acceptor == acceptor,
           cached.expiresAt > refreshBoundary {
            do {
                _ = try verifier.verifyPairGrant(
                    cached.response.grant,
                    keys: keys,
                    initiator: initiator,
                    acceptor: acceptor,
                    now: now
                )
                try Self.requireMatchingGrantExpiry(
                    cached.response,
                    signedExpiry: cached.expiresAt,
                    now: now
                )
                return cached.response
            } catch {
                grantCache.removeValue(forKey: targetIdentity)
            }
        }
        if let deadline = pairGrantRetryDeadline {
            let remaining = Int(ceil(deadline.date.timeIntervalSince(now)))
            if remaining > 0 {
                throw CmxIrohTrustBrokerClientError.rateLimited(
                    code: deadline.code,
                    retryAfterSeconds: remaining
                )
            }
            pairGrantRetryDeadline = nil
        }
        let response: CmxIrohPairGrantResponse
        do {
            response = try await broker.issuePairGrant(
                initiatorBindingID: initiator.bindingID,
                acceptorBindingID: acceptor.bindingID
            )
            pairGrantRetryDeadline = nil
        } catch let error as CmxIrohTrustBrokerClientError {
            if case let .rateLimited(code, retryAfterSeconds) = error {
                pairGrantRetryDeadline = (
                    code: code,
                    date: now.addingTimeInterval(TimeInterval(max(1, retryAfterSeconds)))
                )
            }
            throw error
        }
        let claims = try verifier.verifyPairGrant(
            response.grant,
            keys: keys,
            initiator: initiator,
            acceptor: acceptor,
            now: now
        )
        let signedExpiresAt = Date(timeIntervalSince1970: TimeInterval(claims.expiresAt))
        try Self.requireMatchingGrantExpiry(
            response,
            signedExpiry: signedExpiresAt,
            now: now
        )
        grantCache[targetIdentity] = CmxIrohRegistryGrantCache(
            initiator: initiator,
            acceptor: acceptor,
            response: response,
            expiresAt: signedExpiresAt
        )
        return response
    }

    private func availableNetworkPathSnapshot(
        for hints: [CmxIrohPathHint],
        at clock: Date
    ) async throws -> CmxIrohNetworkPathSnapshot? {
        guard hints.contains(where: {
            $0.privacyScope != .publicInternet && $0.isUsable(at: clock)
        }), let networkPathSnapshot else {
            return nil
        }
        do {
            return try await networkPathSnapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private static func requireMatchingGrantExpiry(
        _ response: CmxIrohPairGrantResponse,
        signedExpiry: Date,
        now: Date
    ) throws {
        guard let responseExpiry = CmxIrohISO8601Date.parse(response.expiresAt),
              abs(responseExpiry.timeIntervalSince(signedExpiry)) < 1,
              signedExpiry > now else {
            throw CmxIrohRegistryContextError.invalidGrantExpiry
        }
    }

    private static func isConnectivity(_ error: any Error) -> Bool {
        (error as? CmxIrohTrustBrokerClientError) == .connectivity
    }
}

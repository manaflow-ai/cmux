public import CMUXMobileCore
import CryptoKit
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
        _ expectedMacDeviceID: String,
        _ expectedInstanceTag: String?
    ) async -> [CmxIrohCustomPrivatePathBootstrap]

    let localEndpointIdentity: @Sendable () async throws -> CmxIrohPeerIdentity
    let broker: any CmxIrohRegistryServing
    var localBindingExpectation: CmxIrohLocalBindingExpectation
    var managedRelayURLs: Set<String>
    var allowedRouteRelayURLs: Set<String>
    let networkPathSnapshot: (@Sendable () async throws -> CmxIrohNetworkPathSnapshot)?
    var offlinePolicy: CmxIrohClientOfflinePolicyContext?
    let lanFallback: LANFallbackProvider?
    let customPrivateFallback: CustomPrivateFallbackProvider?
    let diagnostics: DiagnosticLog?
    let verifier: CmxIrohGrantVerifier
    let now: @Sendable () -> Date
    var grantCache: [CmxIrohPeerIdentity: CmxIrohRegistryGrantCache] = [:]
    /// Macs this phone has completed at least one fully admitted session
    /// with. A member's warm dial carries no credential (allowlist admission)
    /// and performs zero pair-grant fetches.
    var establishedPeers: Set<CmxIrohPeerIdentity> = []
    /// Macs whose last credential-less admission was refused (allowlist miss
    /// or eviction). Their next context carries a pair grant again.
    var credentialRequiredPeers: Set<CmxIrohPeerIdentity> = []
    private var hydratedEstablishedPeers = false
    var pairGrantRetryDeadline: (code: String?, date: Date)?
    var lanAuthorities: [CmxIrohPeerIdentity: CmxIrohRegistryLANAuthority] = [:]
    private var verifiedDiscoverySnapshot: VerifiedDiscoverySnapshot?
    private var authoritativeDiscovery: CmxIrohDiscoveryResponse?
    /// Peers whose last dial produced staleness evidence (an empty dial plan
    /// or an unreachable-class failure). Their next dial bypasses every
    /// discovery reuse window and fetches a fresh broker snapshot.
    private var staleDiscoveryPeers: Set<CmxIrohPeerIdentity> = []
    /// Same staleness marker keyed by canonical Mac device id, for callers
    /// (presence route pushes) that know the device but not its endpoint.
    private var staleDiscoveryDeviceIDs: Set<String> = []
    /// The one in-flight broker discovery fetch. Concurrent dials join it
    /// instead of issuing their own request, so a reconnect burst costs one
    /// broker call and the backpressure gate sees no storm.
    private var sharedDiscoveryTask: Task<CmxIrohDiscoveryResponse, any Error>?

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
        diagnostics: DiagnosticLog? = nil,
        verifiedDiscovery: CmxIrohDiscoveryResponse? = nil,
        verifier: CmxIrohGrantVerifier = CmxIrohGrantVerifier(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        localEndpointIdentity = {
            let endpoint = try await supervisor.activeEndpoint()
            return await endpoint.identity()
        }
        self.broker = broker
        self.localBindingExpectation = localBindingExpectation
        self.managedRelayURLs = managedRelayURLs
        self.allowedRouteRelayURLs = allowedRouteRelayURLs ?? managedRelayURLs
        _ = activeNetworkProfiles
        networkPathSnapshot = nil
        self.offlinePolicy = offlinePolicy
        self.lanFallback = lanFallback
        self.customPrivateFallback = customPrivateFallback
        self.diagnostics = diagnostics
        self.verifier = verifier
        self.now = now
        verifiedDiscoverySnapshot = verifiedDiscovery.map {
            VerifiedDiscoverySnapshot(response: $0, verifiedAt: now())
        }
        authoritativeDiscovery = verifiedDiscovery
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
        diagnostics: DiagnosticLog? = nil,
        verifiedDiscovery: CmxIrohDiscoveryResponse? = nil,
        verifier: CmxIrohGrantVerifier = CmxIrohGrantVerifier(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        localEndpointIdentity = {
            let endpoint = try await supervisor.activeEndpoint()
            return await endpoint.identity()
        }
        self.broker = broker
        self.localBindingExpectation = localBindingExpectation
        self.managedRelayURLs = managedRelayURLs
        self.allowedRouteRelayURLs = allowedRouteRelayURLs ?? managedRelayURLs
        self.networkPathSnapshot = networkPathSnapshot
        self.offlinePolicy = offlinePolicy
        self.lanFallback = lanFallback
        self.customPrivateFallback = customPrivateFallback
        self.diagnostics = diagnostics
        self.verifier = verifier
        self.now = now
        verifiedDiscoverySnapshot = verifiedDiscovery.map {
            VerifiedDiscoverySnapshot(response: $0, verifiedAt: now())
        }
        authoritativeDiscovery = verifiedDiscovery
    }

    /// Creates a provider owned by the unified connectivity endpoint engine.
    public init(
        localEndpointIdentity: @escaping @Sendable () async throws -> CmxIrohPeerIdentity,
        broker: any CmxIrohRegistryServing,
        localBindingExpectation: CmxIrohLocalBindingExpectation,
        managedRelayURLs: Set<String>,
        allowedRouteRelayURLs: Set<String>? = nil,
        networkPathSnapshot: @escaping @Sendable () async throws -> CmxIrohNetworkPathSnapshot,
        offlinePolicy: CmxIrohClientOfflinePolicyContext? = nil,
        lanFallback: LANFallbackProvider? = nil,
        customPrivateFallback: CustomPrivateFallbackProvider? = nil,
        diagnostics: DiagnosticLog? = nil,
        verifiedDiscovery: CmxIrohDiscoveryResponse? = nil,
        verifier: CmxIrohGrantVerifier = CmxIrohGrantVerifier(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.localEndpointIdentity = localEndpointIdentity
        self.broker = broker
        self.localBindingExpectation = localBindingExpectation
        self.managedRelayURLs = managedRelayURLs
        self.allowedRouteRelayURLs = allowedRouteRelayURLs ?? managedRelayURLs
        self.networkPathSnapshot = networkPathSnapshot
        self.offlinePolicy = offlinePolicy
        self.lanFallback = lanFallback
        self.customPrivateFallback = customPrivateFallback
        self.diagnostics = diagnostics
        self.verifier = verifier
        self.now = now
        verifiedDiscoverySnapshot = verifiedDiscovery.map {
            VerifiedDiscoverySnapshot(response: $0, verifiedAt: now())
        }
        authoritativeDiscovery = verifiedDiscovery
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
        let localIdentity = try await localEndpointIdentity()
        guard localBindingExpectation.platform == .ios,
              localBindingExpectation.endpointID == localIdentity else {
            throw CmxIrohRegistryContextError.localBindingUnavailable
        }
        let clock = now()
        // Staleness evidence (a failed dial on an empty/unreachable plan, or
        // a presence route push) bypasses the verified-snapshot reuse window:
        // reuse applies only to healthy-plan dials.
        let requiresFreshDiscovery = discoveryIsMarkedStale(
            identity: targetIdentity,
            deviceID: request.expectedPeerDeviceID
        )
        var usedFreshDiscovery = false
        let discovery: CmxIrohDiscoveryResponse
        if !requiresFreshDiscovery, let verified = takeVerifiedDiscovery(at: clock) {
            discovery = verified
        } else {
            do {
                discovery = try await sharedDiscover(
                    surface: DiagnosticCorrelation().handle(for: targetIdentity.endpointID)
                )
                usedFreshDiscovery = true
            } catch {
                try Task.checkCancellation()
                // The refresh failed. For the transient class (connectivity,
                // broker cooldown, availability blips) dialing with the last
                // verified snapshot beats not dialing at all (cmux#9724): the
                // staleness mark survives, so the next attempt still
                // refetches once the broker recovers. Every other failure is
                // a trust signal (rollback/equivocation detection, a
                // non-transient rejection, invalid authentication, a
                // malformed authority response) and fails closed toward
                // re-discovery instead of being masked by stale identity
                // data.
                if CmxIrohTrustBrokerClientError
                    .preservesVerifiedStateDuringRefresh(error),
                    let lastGood = authoritativeDiscovery {
                    do {
                        return try await resolveContext(
                            for: request,
                            targetIdentity: targetIdentity,
                            routeHints: routeHints,
                            discovery: lastGood,
                            at: clock
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // The last-good snapshot no longer authorizes this
                        // peer; fall through to the offline cache.
                    }
                }
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
                    directOnly: request.irohDirectOnlyDialCandidates,
                    pairGrantToken: cached.pairGrant.grant,
                    at: clock
                )
            }
        }
        if usedFreshDiscovery {
            clearDiscoveryStaleness(
                identity: targetIdentity,
                deviceID: request.expectedPeerDeviceID
            )
        }
        let resolved = try await resolveContext(
            for: request,
            targetIdentity: targetIdentity,
            routeHints: routeHints,
            discovery: discovery,
            at: clock
        )
        // A reused snapshot that yields a plan with no relays and no direct
        // addresses would send the session into a doomed dial. Rebuild once
        // from a fresh snapshot instead; a plan already built from fresh
        // discovery is authoritative, so no second fetch can help it.
        guard !usedFreshDiscovery, Self.dialPlanIsEmpty(resolved.dialPlan) else {
            return resolved
        }
        let freshClock = now()
        let freshDiscovery: CmxIrohDiscoveryResponse
        do {
            freshDiscovery = try await sharedDiscover(
                surface: DiagnosticCorrelation().handle(for: targetIdentity.endpointID)
            )
        } catch {
            // Broker cooldown or connectivity failure: keep the buildable
            // context (its LAN fallback may still connect) instead of
            // spinning against the gate.
            return resolved
        }
        clearDiscoveryStaleness(
            identity: targetIdentity,
            deviceID: request.expectedPeerDeviceID
        )
        do {
            return try await resolveContext(
                for: request,
                targetIdentity: targetIdentity,
                routeHints: routeHints,
                discovery: freshDiscovery,
                at: freshClock
            )
        } catch {
            // The fresh snapshot no longer authorizes this peer. Preserve
            // the prior context so the existing LAN fallback path keeps its
            // chance; the dial failure will re-mark the peer stale.
            return resolved
        }
    }

    private func resolveContext(
        for request: CmxByteTransportRequest,
        targetIdentity: CmxIrohPeerIdentity,
        routeHints: [CmxIrohPathHint],
        discovery: CmxIrohDiscoveryResponse,
        at clock: Date
    ) async throws -> CmxIrohClientContext {
        guard discovery.routeContractVersion == 1 else {
            throw CmxIrohRegistryContextError.incompatibleContract
        }
        // Without a verified managed fleet there is nothing to cross-check and
        // allowedRouteRelayURLs is empty, so no relay hint survives filtering;
        // direct dial plans stay valid while relays remain unusable.
        guard managedRelayURLs.isEmpty
            || Set(discovery.relayFleet) == managedRelayURLs else {
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
        // Already-paired Mac: dial credential-less and let the Mac's
        // persisted allowlist admit the TLS-proven EndpointID. Zero grant
        // HTTP calls on this hot path; a refusal falls back through
        // noteAllowlistAdmissionRefused to the grant fetch below.
        if !credentialRequiredPeers.contains(targetIdentity),
           await isEstablished(targetIdentity) {
            return try await context(
                targetBinding: targetBinding,
                routeHints: routeHints,
                directOnly: request.irohDirectOnlyDialCandidates,
                pairGrantToken: nil,
                at: clock
            )
        }
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
            // Backpressure may reuse an existing signed grant only after this
            // discovery has re-confirmed both exact endpoint authorities.
            guard Self.isConnectivity(error)
                    || CmxIrohBrokerCooldown.directiveSeconds(for: error) != nil,
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
                directOnly: request.irohDirectOnlyDialCandidates,
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
            directOnly: request.irohDirectOnlyDialCandidates,
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
            authoritativeDiscovery = nil
            staleDiscoveryPeers.removeAll(keepingCapacity: false)
            staleDiscoveryDeviceIDs.removeAll(keepingCapacity: false)
            establishedPeers.removeAll(keepingCapacity: false)
            credentialRequiredPeers.removeAll(keepingCapacity: false)
            hydratedEstablishedPeers = false
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
            authoritativeDiscovery = verifiedDiscovery
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

    /// Fetches one broker discovery snapshot, coalescing concurrent callers
    /// onto the same in-flight request. The broker seam already serializes and
    /// floors requests through ``CmxIrohBrokerBackpressureGate``; sharing the
    /// task means a burst of dials consumes one quota unit instead of queuing
    /// one request per dial. A gate cooldown propagates unchanged so callers
    /// wait out the directive instead of spinning.
    private func sharedDiscover(
        surface: UInt32? = nil
    ) async throws -> CmxIrohDiscoveryResponse {
        if let sharedDiscoveryTask {
            return try await sharedDiscoveryTask.value
        }
        let broker = broker
        let cached = authoritativeDiscovery
        let startedAt = DispatchTime.now().uptimeNanoseconds
        diagnostics?.record(DiagnosticEvent(
            .discoveryStarted,
            surface: surface,
            a: DiagnosticTransportKind.iroh.rawValue
        ))
        let task = Task {
            try await CmxAuthoritativeDiscoveryResolver(broker: broker).resolve(
                cached: cached
            )
        }
        sharedDiscoveryTask = task
        defer { sharedDiscoveryTask = nil }
        do {
            let response = try await task.value
            authoritativeDiscovery = response
            diagnostics?.record(DiagnosticEvent(
                .discoverySucceeded,
                surface: surface,
                ms: elapsedMilliseconds(since: startedAt),
                a: DiagnosticTransportKind.iroh.rawValue,
                b: response.bindings.count,
                c: response.relayFleet.count
            ))
            return response
        } catch {
            diagnostics?.record(DiagnosticEvent(
                .discoveryFailed,
                surface: surface,
                ms: elapsedMilliseconds(since: startedAt),
                a: DiagnosticTransportKind.iroh.rawValue,
                b: DiagnosticFailureKind.classify(error).rawValue
            ))
            throw error
        }
    }

    private func elapsedMilliseconds(since start: UInt64) -> UInt32 {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= start ? now - start : 0
        return UInt32(clamping: elapsed / 1_000_000)
    }

    /// Records dial-failure evidence from the session pool. An empty plan or
    /// an unreachable-class failure marks the peer's discovery state stale, so
    /// the next dial bypasses every reuse window and rebuilds its plan from a
    /// fresh broker snapshot instead of redialing a corpse route.
    public func noteDialFailure(
        for request: CmxByteTransportRequest,
        dialPlan: CmxIrohDialPlan,
        failure: DiagnosticFailureKind
    ) async {
        guard request.route.kind == .iroh,
              case let .peer(targetIdentity, _) = request.route.endpoint else {
            return
        }
        let planWasEmpty = Self.dialPlanIsEmpty(dialPlan)
        guard planWasEmpty || Self.indicatesUnreachablePeer(failure) else {
            return
        }
        markDiscoveryStale(
            identity: targetIdentity,
            deviceID: request.expectedPeerDeviceID
        )
    }

    /// Invalidates reusable discovery state for one Mac (or, with `nil`, for
    /// every peer). Used when a presence route push proves the Mac's endpoint
    /// re-registered: the next dial must refetch instead of reusing a snapshot
    /// captured before the relaunch.
    public func invalidateVerifiedDiscovery(forDeviceID deviceID: String? = nil) {
        verifiedDiscoverySnapshot = nil
        guard let deviceID else {
            staleDiscoveryPeers.removeAll(keepingCapacity: false)
            staleDiscoveryDeviceIDs.removeAll(keepingCapacity: false)
            return
        }
        staleDiscoveryDeviceIDs.insert(Self.canonicalDeviceID(deviceID))
    }

    private func markDiscoveryStale(
        identity: CmxIrohPeerIdentity,
        deviceID: String?
    ) {
        // The snapshot predates the staleness evidence; nothing may reuse it.
        verifiedDiscoverySnapshot = nil
        staleDiscoveryPeers.insert(identity)
        if let deviceID {
            staleDiscoveryDeviceIDs.insert(Self.canonicalDeviceID(deviceID))
        }
    }

    private func clearDiscoveryStaleness(
        identity: CmxIrohPeerIdentity,
        deviceID: String?
    ) {
        staleDiscoveryPeers.remove(identity)
        if let deviceID {
            staleDiscoveryDeviceIDs.remove(Self.canonicalDeviceID(deviceID))
        }
    }

    private func discoveryIsMarkedStale(
        identity: CmxIrohPeerIdentity,
        deviceID: String?
    ) -> Bool {
        if staleDiscoveryPeers.contains(identity) { return true }
        guard let deviceID else { return false }
        return staleDiscoveryDeviceIDs.contains(Self.canonicalDeviceID(deviceID))
    }

    private static func canonicalDeviceID(_ deviceID: String) -> String {
        CmxIrohDeviceID(deviceID)?.value
            ?? deviceID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func dialPlanIsEmpty(_ dialPlan: CmxIrohDialPlan) -> Bool {
        dialPlan.publicPaths.isEmpty && dialPlan.privateFallbackPaths.isEmpty
    }

    /// Failure classes that mean the dialed endpoint state, not our request,
    /// was bad: the peer could not be reached on the plan we used. Auth,
    /// admission, cancellation, and local-policy failures stay out; refetching
    /// discovery cannot repair those and would only burn broker quota.
    private static func indicatesUnreachablePeer(
        _ failure: DiagnosticFailureKind
    ) -> Bool {
        switch failure {
        case .timedOut,
             .hostUnreachable,
             .connectionRefused,
             .connectionClosed,
             .noRoute,
             .transportIdleTimedOut:
            return true
        case .none, .offline, .permissionDenied, .dnsFailed,
             .secureChannelFailed, .unsupportedRoute, .credentialUnavailable,
             .policyUnavailable, .endpointUnavailable, .identityMismatch,
             .admissionDenied, .authorizationFailed, .accountMismatch,
             .protocolViolation, .superseded, .cancelled,
             .admissionLeaseExpired, .admissionRevalidationFailed,
             .sendQueueOverflow, .payloadTooLarge, .resourceLimitReached,
             .attachmentCountLimitReached, .attachmentAggregateSizeLimitReached,
             .localStateUnavailable, .routeGated, .unknown:
            return false
    }
    }

    private func context(
        targetBinding: CmxIrohBrokerBinding,
        routeHints: [CmxIrohPathHint],
        directOnly: [CmxIrohDirectDialCandidate]? = nil,
        pairGrantToken: String?,
        at clock: Date
    ) async throws -> CmxIrohClientContext {
        if let directOnly {
            return try directOnlyContext(
                candidates: directOnly,
                targetBinding: targetBinding,
                pairGrantToken: pairGrantToken,
                at: clock
            )
        }
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
            credential: try pairGrantToken.map(CmxIrohAdmissionCredential.pairGrant),
            privateFallbackAuthorization: fallbackAuthorization
        )
    }

    /// Builds the exclusive dial context for the per-Computer Direct method.
    ///
    /// The user-enabled candidates are the COMPLETE path allowlist: the broker
    /// binding's advertised relay and direct paths, LAN discovery, and custom
    /// private-path joins are all skipped. The broker still authenticates the
    /// target tuple and signs the pair grant, so authorization is unchanged;
    /// only path selection is pinned. Explicit candidate ports are used
    /// verbatim while port-less candidates join the broker-published Iroh UDP
    /// port for their address family. Zero usable joins fails the dial instead
    /// of substituting another path, keeping Direct fail-closed.
    ///
    /// The pinned hints deliberately ride `publicPaths`, the unconditional
    /// primary dial leg. The private-fallback machinery (profile gating,
    /// snapshot generations, revalidation) exists to keep AUTOMATICALLY
    /// discovered private addresses off the wrong network; a user-pinned
    /// exclusive allowlist is an explicit instruction to dial exactly these,
    /// and peer identity is still proven by the QUIC handshake against the
    /// broker-authenticated EndpointID.
    private func directOnlyContext(
        candidates: [CmxIrohDirectDialCandidate],
        targetBinding: CmxIrohBrokerBinding,
        pairGrantToken: String?,
        at clock: Date
    ) throws -> CmxIrohClientContext {
        let peerAlias = DiagnosticCorrelation().handle(for: targetBinding.deviceID)
        guard !candidates.isEmpty else {
            diagnostics?.record(DiagnosticEvent(
                .transportPrivateAddressJoin,
                surface: peerAlias,
                a: DiagnosticPrivateAddressJoinState.notConfigured.rawValue,
                b: 0,
                c: 0
            ))
            throw CmxIrohRegistryContextError.dialPlanUnavailable
        }
        let directPorts = freshDirectPorts(targetBinding: targetBinding, at: clock)
        let profile = Self.directOnlyNetworkProfile(deviceID: targetBinding.deviceID)
        var hints: [CmxIrohPathHint] = []
        for candidate in candidates.prefix(CmxAttachEndpoint.maximumIrohPathHintCount) {
            guard let address = try? CmxIrohCustomPrivateAddress(candidate.address) else {
                continue
            }
            let port: UInt16?
            if let explicitPort = candidate.port {
                port = explicitPort
            } else {
                switch address.family {
                case .ipv4: port = directPorts?.ipv4
                case .ipv6: port = directPorts?.ipv6
                }
            }
            guard let port, let profile,
                  let hint = try? CmxIrohPathHint(
                      kind: .directAddress,
                      value: address.socketAddress(port: port),
                      source: .customVPN,
                      privacyScope: .privateNetwork,
                      observedAt: clock,
                      expiresAt: clock.addingTimeInterval(
                          CmxIrohPathHint.maximumPrivateHintTTL
                      ),
                      networkProfile: profile
                  ),
                  !hints.contains(hint) else { continue }
            hints.append(hint)
        }
        guard let dialPlan = CmxIrohDialPlan.directOnly(pinnedPaths: hints) else {
            diagnostics?.record(DiagnosticEvent(
                .transportPrivateAddressJoin,
                surface: peerAlias,
                a: DiagnosticPrivateAddressJoinState.brokerPortsStale.rawValue,
                b: candidates.count,
                c: 0
            ))
            throw CmxIrohRegistryContextError.dialPlanUnavailable
        }
        diagnostics?.record(DiagnosticEvent(
            .transportPrivateAddressJoin,
            surface: peerAlias,
            a: DiagnosticPrivateAddressJoinState.joined.rawValue,
            b: candidates.count,
            c: hints.count
        ))
        return CmxIrohClientContext(
            dialPlan: dialPlan,
            credential: try pairGrantToken.map(CmxIrohAdmissionCredential.pairGrant),
            privateFallbackAuthorization: nil
        )
    }

    /// Deterministic routing-metadata profile for user-pinned Direct hints.
    /// It carries hint provenance only; Direct dials are not profile-gated.
    private static func directOnlyNetworkProfile(
        deviceID: String
    ) -> CmxIrohNetworkProfileKey? {
        let digest = SHA256.hash(
            data: Data("direct-only-allowlist-v1\0\(deviceID)".utf8)
        )
        let profileID = digest.map { String(format: "%02x", $0) }.joined()
        return try? CmxIrohNetworkProfileKey(
            source: .customVPN,
            profileID: profileID
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
        guard let customPrivateFallback else { return [] }
        let configured = await customPrivateFallback(
            targetBinding.deviceID,
            targetBinding.tag
        )
        let peerAlias = DiagnosticCorrelation().handle(for: targetBinding.deviceID)
        guard !configured.isEmpty else {
            diagnostics?.record(DiagnosticEvent(
                .transportPrivateAddressJoin,
                surface: peerAlias,
                a: DiagnosticPrivateAddressJoinState.notConfigured.rawValue,
                b: 0,
                c: 0
            ))
            return []
        }
        guard let directPorts = freshDirectPorts(
            targetBinding: targetBinding,
            at: clock
        ) else {
            diagnostics?.record(DiagnosticEvent(
                .transportPrivateAddressJoin,
                surface: peerAlias,
                a: DiagnosticPrivateAddressJoinState.brokerPortsStale.rawValue,
                b: configured.count,
                c: 0
            ))
            return []
        }
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
        diagnostics?.record(DiagnosticEvent(
            .transportPrivateAddressJoin,
            surface: peerAlias,
            a: DiagnosticPrivateAddressJoinState.joined.rawValue,
            b: configured.count,
            c: hints.count
        ))
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
              case let .peer(targetIdentity, _) = request.route.endpoint else {
            return context
        }
        // A Direct-only dial's allowlist is complete: LAN-discovered hints
        // must not widen it, so its context is returned untouched.
        guard request.irohDirectOnlyDialCandidates == nil else {
            return context
        }
        guard let authority = lanAuthorities[targetIdentity],
              authority.target.endpointID == targetIdentity,
              CmxIrohDeviceID(authority.target.deviceID)
                == CmxIrohDeviceID(expectedDeviceID) else {
            // Without a broker-issued LAN authority no browse can run, so the
            // absent stage is recorded here instead of failing silently.
            diagnostics?.record(DiagnosticEvent(
                .transportLANDiscovery,
                surface: DiagnosticCorrelation().handle(for: expectedDeviceID),
                a: DiagnosticLANDiscoveryOutcome.noAuthority.rawValue,
                b: 0
            ))
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
        for target in pairableMacs where counts[target.endpointID] == 1 {
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

    /// Records one fully admitted session: later warm dials to this Mac go
    /// credential-less and skip the pair-grant fetch entirely. The marker is
    /// also persisted through the offline policy cache so it survives
    /// relaunch; persistence failure only costs the fast path.
    public func noteAdmissionSucceeded(for request: CmxByteTransportRequest) async {
        guard request.route.kind == .iroh,
              case let .peer(targetIdentity, _) = request.route.endpoint else {
            return
        }
        credentialRequiredPeers.remove(targetIdentity)
        guard !establishedPeers.contains(targetIdentity) else { return }
        establishedPeers.insert(targetIdentity)
        guard let offlinePolicy else { return }
        try? await offlinePolicy.cache.setSessionEstablished(
            true,
            targetEndpointID: targetIdentity,
            for: offlinePolicy.expectation,
            confirmedLocalBinding: offlinePolicy.localBinding,
            now: now()
        )
    }

    /// Records a refused credential-less admission: the Mac has no (or a
    /// stale) allowlist entry for this phone, so the next context must carry
    /// a pair grant again. The persisted marker is cleared so a relaunch does
    /// not retry the refused path first.
    public func noteAllowlistAdmissionRefused(
        for request: CmxByteTransportRequest
    ) async {
        guard request.route.kind == .iroh,
              case let .peer(targetIdentity, _) = request.route.endpoint else {
            return
        }
        establishedPeers.remove(targetIdentity)
        credentialRequiredPeers.insert(targetIdentity)
        guard let offlinePolicy else { return }
        try? await offlinePolicy.cache.setSessionEstablished(
            false,
            targetEndpointID: targetIdentity,
            for: offlinePolicy.expectation,
            confirmedLocalBinding: offlinePolicy.localBinding,
            now: now()
        )
    }

    private func isEstablished(_ identity: CmxIrohPeerIdentity) async -> Bool {
        if establishedPeers.contains(identity) { return true }
        guard !hydratedEstablishedPeers, let offlinePolicy else { return false }
        hydratedEstablishedPeers = true
        let persisted = (try? await offlinePolicy.cache.establishedTargetEndpointIDs(
            for: offlinePolicy.expectation,
            confirmedLocalBinding: offlinePolicy.localBinding,
            now: now()
        )) ?? []
        establishedPeers.formUnion(persisted)
        return establishedPeers.contains(identity)
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

public import CMUXMobileCore
public import Foundation

/// Resolves fresh same-account reachability and a locally verified pair grant per dial.
public actor CmxIrohRegistryContextProvider: CmxIrohClientContextProvider {
    private struct GrantCache: Sendable {
        let initiator: CmxIrohGrantPeer
        let acceptor: CmxIrohGrantPeer
        let token: String
        let expiresAt: Date
    }

    private let supervisor: CmxIrohEndpointSupervisor
    private let broker: any CmxIrohRegistryServing
    private let localBindingExpectation: CmxIrohLocalBindingExpectation
    private let managedRelayURLs: Set<String>
    private let networkPathSnapshot: (@Sendable () async throws -> CmxIrohNetworkPathSnapshot)?
    private let verifier: CmxIrohGrantVerifier
    private let now: @Sendable () -> Date
    private var grantCache: [CmxIrohPeerIdentity: GrantCache] = [:]

    /// Creates a public-route provider from the legacy generation-less seam.
    ///
    /// Private hints remain disabled because a profile set alone cannot prove
    /// that the network path stayed unchanged between admission and fallback.
    public init(
        supervisor: CmxIrohEndpointSupervisor,
        broker: any CmxIrohRegistryServing,
        localBindingExpectation: CmxIrohLocalBindingExpectation,
        managedRelayURLs: Set<String>,
        activeNetworkProfiles: @escaping @Sendable () async -> Set<CmxIrohNetworkProfileKey>,
        verifier: CmxIrohGrantVerifier = CmxIrohGrantVerifier(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.supervisor = supervisor
        self.broker = broker
        self.localBindingExpectation = localBindingExpectation
        self.managedRelayURLs = managedRelayURLs
        _ = activeNetworkProfiles
        networkPathSnapshot = nil
        self.verifier = verifier
        self.now = now
    }

    /// Creates a provider with generation-aware private-network validation.
    public init(
        supervisor: CmxIrohEndpointSupervisor,
        broker: any CmxIrohRegistryServing,
        localBindingExpectation: CmxIrohLocalBindingExpectation,
        managedRelayURLs: Set<String>,
        networkPathSnapshot: @escaping @Sendable () async throws -> CmxIrohNetworkPathSnapshot,
        verifier: CmxIrohGrantVerifier = CmxIrohGrantVerifier(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.supervisor = supervisor
        self.broker = broker
        self.localBindingExpectation = localBindingExpectation
        self.managedRelayURLs = managedRelayURLs
        self.networkPathSnapshot = networkPathSnapshot
        self.verifier = verifier
        self.now = now
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
        let endpoint = try await supervisor.activeEndpoint()
        let localIdentity = await endpoint.identity()
        guard localBindingExpectation.platform == .ios,
              localBindingExpectation.endpointID == localIdentity else {
            throw CmxIrohRegistryContextError.localBindingUnavailable
        }
        let discovery = try await broker.discover()
        guard discovery.routeContractVersion == 1 else {
            throw CmxIrohRegistryContextError.incompatibleContract
        }
        guard Set(discovery.relayFleet) == managedRelayURLs else {
            throw CmxIrohRegistryContextError.relayFleetMismatch
        }
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
              targetBinding.deviceID == expectedPeerDeviceID else {
            throw CmxIrohRegistryContextError.targetDeviceMismatch
        }
        guard targetBinding.pairingEnabled else {
            throw CmxIrohRegistryContextError.targetNotPairable
        }
        let initiator = CmxIrohGrantPeer(binding: localBinding)
        let acceptor = CmxIrohGrantPeer(binding: targetBinding)
        let clock = now()
        let token = try await grant(
            initiator: initiator,
            acceptor: acceptor,
            targetIdentity: targetIdentity,
            keys: discovery.grantVerificationKeys,
            now: clock
        )
        let pathSnapshot = try await availableNetworkPathSnapshot(
            for: targetBinding.pathHints + routeHints,
            at: clock
        )
        let profiles = pathSnapshot?.activeNetworkProfiles ?? []
        let hints = Self.mergeHints(
            primary: targetBinding.pathHints,
            fallback: routeHints,
            at: clock,
            managedRelayURLs: managedRelayURLs,
            activeNetworkProfiles: profiles
        )
        let endpointAddress = CmxAttachEndpoint.peer(
            identity: targetIdentity,
            pathHints: hints
        )
        guard let dialPlan = endpointAddress.irohDialPlan(
            at: clock,
            managedRelayURLs: managedRelayURLs,
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
            credential: try .pairGrant(token),
            privateFallbackAuthorization: fallbackAuthorization
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
    ) async throws -> String {
        let refreshBoundary = now.addingTimeInterval(72 * 60 * 60)
        if let cached = grantCache[targetIdentity],
           cached.initiator == initiator,
           cached.acceptor == acceptor,
           cached.expiresAt > refreshBoundary {
            do {
                _ = try verifier.verifyPairGrant(
                    cached.token,
                    keys: keys,
                    initiator: initiator,
                    acceptor: acceptor,
                    now: now
                )
                return cached.token
            } catch {
                grantCache.removeValue(forKey: targetIdentity)
            }
        }
        let response = try await broker.issuePairGrant(
            initiatorBindingID: initiator.bindingID,
            acceptorBindingID: acceptor.bindingID
        )
        let claims = try verifier.verifyPairGrant(
            response.grant,
            keys: keys,
            initiator: initiator,
            acceptor: acceptor,
            now: now
        )
        let signedExpiresAt = Date(timeIntervalSince1970: TimeInterval(claims.expiresAt))
        guard let responseExpiresAt = Self.date(response.expiresAt),
              abs(responseExpiresAt.timeIntervalSince(signedExpiresAt)) < 1,
              signedExpiresAt > now else {
            throw CmxIrohRegistryContextError.invalidGrantExpiry
        }
        grantCache[targetIdentity] = GrantCache(
            initiator: initiator,
            acceptor: acceptor,
            token: response.grant,
            expiresAt: signedExpiresAt
        )
        return response.grant
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

    private static func mergeHints(
        primary: [CmxIrohPathHint],
        fallback: [CmxIrohPathHint],
        at now: Date,
        managedRelayURLs: Set<String>,
        activeNetworkProfiles: Set<CmxIrohNetworkProfileKey>
    ) -> [CmxIrohPathHint] {
        var result: [CmxIrohPathHint] = []
        for hint in primary + fallback where hint.isUsable(at: now) {
            guard isEligible(
                hint,
                managedRelayURLs: managedRelayURLs,
                activeNetworkProfiles: activeNetworkProfiles
            ) else {
                continue
            }
            if !result.contains(where: { sameRoute($0, hint) }) {
                result.append(hint)
            }
            if result.count == CmxAttachEndpoint.maximumIrohPathHintCount { break }
        }
        return result
    }

    private static func isEligible(
        _ hint: CmxIrohPathHint,
        managedRelayURLs: Set<String>,
        activeNetworkProfiles: Set<CmxIrohNetworkProfileKey>
    ) -> Bool {
        if hint.privacyScope != .publicInternet {
            guard let profile = hint.networkProfile else { return false }
            return activeNetworkProfiles.contains(profile)
        }
        switch hint.kind {
        case .directAddress:
            return true
        case .relayURL:
            return managedRelayURLs.contains(hint.value)
        case .relayIdentifier:
            return false
        }
    }

    private static func sameRoute(_ left: CmxIrohPathHint, _ right: CmxIrohPathHint) -> Bool {
        left.kind == right.kind
            && left.value == right.value
            && left.source == right.source
            && left.privacyScope == right.privacyScope
            && left.networkProfile == right.networkProfile
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

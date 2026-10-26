import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileTransport
import CmuxSurfaceCatalogModel
import Foundation

/// The Mac's `MobileSyncRuntime`: what the shared RPC client needs from the
/// app to dial another Mac. Tokens come through ``HiveAccountTokenSource`` and
/// are bound to the signed-in account generation. When the account Mac
/// directory is enabled, a selected-team change is independent of an
/// account-owned device link; the feature flag's rollback path uses the
/// selected team as before.
/// Transports come from the shared Network.framework factory the iOS app uses,
/// restricted to the route kinds ``DeviceRouteSelector`` admits.
struct DeviceLinkRuntime: MobileSyncRuntime {
    private(set) var transportFactory: any CmxByteTransportFactory
    private(set) var independentEventByteStreamProvider: CmxIndependentEventByteStreamProvider?
    let automaticClient: DeviceIrxClient?
    let routeSelector: DeviceRouteSelector
    let stackAccessTokenProvider: @Sendable () async throws -> String
    let stackAccessTokenForceRefresher: @Sendable () async throws -> String
    let stackAccessTokenForStatusProvider: @Sendable () async -> String?
    let supportedRouteKinds: [CmxAttachTransportKind]
    let rpcRequestTimeoutNanoseconds: UInt64
    let pairingRequestTimeoutNanoseconds: UInt64
    let now: @Sendable () -> Date
    let supportsServerPushEvents: Bool = true

    static func defaultRouteSelector(hasAutomaticClient: Bool) -> DeviceRouteSelector {
        DeviceRouteSelector(allowsIroh: hasAutomaticClient)
    }

    init(
        tokens: HiveAccountTokenSource,
        automaticClient: DeviceIrxClient? = nil,
        routeSelector: DeviceRouteSelector? = nil,
        rpcRequestTimeoutNanoseconds: UInt64 = 20_000_000_000,
        pairingRequestTimeoutNanoseconds: UInt64 = 10_000_000_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.automaticClient = automaticClient
        let routeSelector = routeSelector ?? Self.defaultRouteSelector(hasAutomaticClient: automaticClient != nil)
        self.routeSelector = routeSelector
        transportFactory = CmxNetworkByteTransportFactory(supportedKinds: routeSelector.supportedKinds.filter { $0 != .iroh })
        independentEventByteStreamProvider = nil
        stackAccessTokenProvider = { try await tokens.session().accessToken }
        stackAccessTokenForceRefresher = { try await tokens.refresh() }
        stackAccessTokenForStatusProvider = { await tokens.cachedToken() }
        supportedRouteKinds = routeSelector.supportedKinds
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.now = now
    }

    static func makeTransportFactory(
        routeSelector: DeviceRouteSelector,
        automaticFactory: any CmxByteTransportFactory,
        fallbackFactory: any CmxByteTransportFactory
    ) throws -> CmxRouteTransportFactory {
        let registrations = routeSelector.supportedKinds.map { kind in
            CmxRouteTransportFactoryRegistration(
                kind: kind,
                factory: kind == .iroh ? automaticFactory : fallbackFactory
            )
        }
        return try CmxRouteTransportFactory(registrations)
    }

    func forPeer(_ instance: SurfaceDeviceInstanceID) throws -> DeviceLinkRuntime {
        guard let automaticClient else { return self }
        let automatic = CmxConnectivityDeferredTransportFactory(
            provider: DeviceIrxPeerTransportProvider(client: automaticClient, instance: instance)
        )
        var result = self
        result.transportFactory = try Self.makeTransportFactory(
            routeSelector: routeSelector,
            automaticFactory: automatic,
            fallbackFactory: transportFactory
        )
        result.independentEventByteStreamProvider = { request in
            try await automaticClient.events(for: request, instance: instance)
        }
        return result
    }
}

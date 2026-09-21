import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation

/// The Mac's `MobileSyncRuntime`: what the shared RPC client needs from the
/// app to dial another Mac. Tokens come through ``HiveAccountTokenSource``,
/// bound to the account generation and team scope the directory was built for
/// (the same identity the host verifies): after a sign-out or account switch
/// every token call fails instead of carrying the next account's token.
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

    init(
        tokens: HiveAccountTokenSource,
        automaticClient: DeviceIrxClient? = nil,
        routeSelector: DeviceRouteSelector? = nil,
        rpcRequestTimeoutNanoseconds: UInt64 = 20_000_000_000,
        pairingRequestTimeoutNanoseconds: UInt64 = 10_000_000_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.automaticClient = automaticClient
        let routeSelector = routeSelector ?? DeviceRouteSelector(allowsIroh: automaticClient != nil, allowsLegacyTailscale: automaticClient == nil)
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

    func forPeer(_ instance: SurfaceDeviceInstanceID) throws -> DeviceLinkRuntime {
        guard let automaticClient else { return self }
        let automatic = CmxConnectivityDeferredTransportFactory(
            provider: DeviceIrxPeerTransportProvider(client: automaticClient, instance: instance)
        )
        var result = self
        result.transportFactory = try CmxRouteTransportFactory([
            CmxRouteTransportFactoryRegistration(kind: .iroh, factory: automatic)
        ])
        result.independentEventByteStreamProvider = { request in
            try await automaticClient.events(for: request, instance: instance)
        }
        return result
    }
}

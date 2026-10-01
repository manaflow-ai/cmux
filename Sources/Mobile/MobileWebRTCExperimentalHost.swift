#if DEBUG
import CmuxMobileHost
import CmuxMobileTransport
import CMUXMobileCore
import Foundation

/// Owns the opt-in macOS WebRTC signaling listener used by tagged experiments.
///
/// The listener is created only when `CMUX_WEBRTC_EXPERIMENT=1` is present in a
/// DEBUG process. Its token-bearing routes are published only in authenticated
/// host status and attach tickets; the public reachability probe filters them.
@MainActor
final class MobileWebRTCExperimentalHost {
    private let defaults: UserDefaults
    private let routeResolver = MobileRouteResolver()
    private let configuration: CmxWebRTCConfiguration
    private var server: CmxWebRTCSignalingServer?

    init(defaults: UserDefaults = .standard, environment: [String: String]) {
        self.defaults = defaults
        configuration = CmxWebRTCConfiguration(
            environment: environment,
            userDefaults: defaults
        )
    }

    func start() {
        guard server == nil else { return }
        let nextServer = CmxWebRTCSignalingServer(
            preferredPort: MobileHostService.configuredPort(defaults: defaults),
            configuration: configuration
        ) { transport in
            await MobileHostService.acceptTransport(
                transport,
                authorization: .stackBearer,
                isCurrent: { MobileHostService.isListeningEnabled }
            )
        }
        server = nextServer
        Task { @MainActor [weak self, nextServer] in
            do {
                try await nextServer.start()
                await self?.publishRoutes(using: nextServer)
            } catch {
                MobileHostPublicStatusCache.clearWebRTCRoutes()
            }
        }
    }

    func refreshRoutes() {
        guard let server else { return }
        Task { @MainActor [weak self, server] in
            await self?.publishRoutes(using: server)
        }
    }

    func stop() {
        let currentServer = server
        server = nil
        MobileHostPublicStatusCache.clearWebRTCRoutes()
        guard let currentServer else { return }
        Task { await currentServer.stop() }
    }

    private func publishRoutes(using server: CmxWebRTCSignalingServer) async {
        guard let endpoint = await server.endpoint() else {
            MobileHostPublicStatusCache.clearWebRTCRoutes()
            return
        }
        let snapshot = await routeResolver.routesResolvingTailscaleDNS(port: endpoint.port)
        var routes: [CmxAttachRoute] = []
        routes.reserveCapacity(snapshot.routes.count)
        for route in snapshot.routes where route.kind == .tailscale {
            guard case let .hostPort(host, _) = route.endpoint,
                  let url = await server.routeURL(host: host),
                  let webRTCRoute = try? CmxAttachRoute(
                      id: routes.isEmpty ? CmxAttachTransportKind.webrtc.rawValue :
                          "\(CmxAttachTransportKind.webrtc.rawValue)_\(routes.count + 1)",
                      kind: .webrtc,
                      endpoint: .url(url),
                      priority: -20_000 + routes.count
                  ) else {
                continue
            }
            routes.append(webRTCRoute)
        }
        MobileHostPublicStatusCache.update(webRTCRoutes: routes)
    }
}
#endif

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
    private let configuration: CmxWebRTCConfiguration
    private let iceServersProvider: CmxWebRTCIceServersProvider?
    private let signalingRelayURL: URL?
    private let signalingAccessTokenProvider: CmxWebRTITokenProvider?
    private var server: CmxWebRTCSignalingServer?

    init(
        defaults: UserDefaults = .standard,
        environment: [String: String],
        iceServersProvider: CmxWebRTCIceServersProvider? = nil,
        signalingRelayURL: URL? = nil,
        signalingAccessTokenProvider: CmxWebRTITokenProvider? = nil
    ) {
        self.defaults = defaults
        self.iceServersProvider = iceServersProvider
        self.signalingRelayURL = signalingRelayURL
        self.signalingAccessTokenProvider = signalingAccessTokenProvider
        configuration = CmxWebRTCConfiguration(
            environment: environment,
            userDefaults: defaults
        )
    }

    func start() {
        guard server == nil else { return }
        let nextServer = CmxWebRTCSignalingServer(
            preferredPort: MobileHostService.configuredPort(defaults: defaults),
            configuration: configuration,
            iceServersProvider: iceServersProvider,
            signalingRelayURL: signalingRelayURL,
            signalingAccessTokenProvider: signalingAccessTokenProvider
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
        guard signalingRelayURL != nil, let rawURL = await server.routeURL(),
              let route = try? CmxAttachRoute(
                  id: CmxAttachTransportKind.webrtc.rawValue,
                  kind: .webrtc,
                  endpoint: .url(rawURL),
                  priority: -20_000
              ) else {
            MobileHostPublicStatusCache.clearWebRTCRoutes()
            return
        }
        MobileHostPublicStatusCache.update(webRTCRoutes: [route])
    }
}
#endif

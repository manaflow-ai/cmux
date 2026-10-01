import Foundation
@preconcurrency import Network

/// A macOS-side TCP bootstrap that exchanges SDP and ICE candidates for WebRTC peers.
public actor CmxWebRTCSignalingServer {
    /// Called after a peer has authenticated the route token and opened its data channel.
    public typealias TransportHandler = @Sendable (CmxWebRTCByteTransport) async -> Void

    private let preferredPort: Int
    private let configuration: CmxWebRTCConfiguration
    private let token: String
    private let transportHandler: TransportHandler
    private let callbackQueue: DispatchQueue
    private var listener: NWListener?
    private var boundPort: Int?
    private var startContinuation: CheckedContinuation<Void, any Error>?
    private var activeTransports: [UUID: CmxWebRTCByteTransport] = [:]

    /// Creates a signaling server.
    ///
    /// - Parameters:
    ///   - preferredPort: TCP port to try first. A zero or invalid value uses an ephemeral port.
    ///   - configuration: ICE and timeout settings for accepted peers.
    ///   - transportHandler: Callback that admits an opened data channel to the host RPC service.
    public init(
        preferredPort: Int,
        configuration: CmxWebRTCConfiguration,
        transportHandler: @escaping TransportHandler
    ) {
        self.preferredPort = (1...65535).contains(preferredPort) ? preferredPort : 0
        self.configuration = configuration
        token = UUID().uuidString
        self.transportHandler = transportHandler
        callbackQueue = DispatchQueue(
            label: "dev.cmux.mobile.webrtc-signaling-listener.\(UUID().uuidString)"
        )
    }

    /// Starts listening and falls back to an ephemeral TCP port if the preferred port is busy.
    ///
    /// - Throws: A Network.framework listener error when neither port can bind.
    public func start() async throws {
        guard listener == nil else { return }
        do {
            try await bind(port: preferredPort)
        } catch {
            guard preferredPort != 0 else { throw error }
            try await bind(port: 0)
        }
    }

    /// Returns the current route token and bound port for publishing an attach route.
    ///
    /// - Returns: The listener details, or nil before `start()` succeeds.
    public func endpoint() -> (port: Int, token: String)? {
        guard let boundPort else { return nil }
        return (boundPort, token)
    }

    /// Builds the route URL for one host address without logging or storing the token elsewhere.
    ///
    /// - Parameter host: A host address reachable by the iOS peer.
    /// - Returns: A token-bearing `webrtc://` URL, or nil while stopped.
    public func routeURL(host: String) -> String? {
        guard let boundPort,
              let encodedHost = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "webrtc"
        components.host = encodedHost
        components.port = boundPort
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.string
    }

    /// Stops accepting new signaling connections and closes active WebRTC peers.
    public func stop() async {
        listener?.cancel()
        listener = nil
        boundPort = nil
        startContinuation?.resume(throwing: CmxWebRTCSignalingError.closed)
        startContinuation = nil
        let transports = activeTransports.values
        activeTransports.removeAll()
        for transport in transports {
            await transport.close()
        }
    }

    private func bind(port: Int) async throws {
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? .any
        let nextListener = try NWListener(using: .tcp, on: endpointPort)
        listener = nextListener
        nextListener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(listenerState: state) }
        }
        nextListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection: connection) }
        }
        nextListener.start(queue: callbackQueue)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            startContinuation = continuation
        }
    }

    private func handle(listenerState state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                boundPort = Int(port.rawValue)
            } else {
                boundPort = nil
            }
            guard boundPort != nil else {
                startContinuation?.resume(throwing: CmxWebRTCSignalingError.connectionFailed("missing listener port"))
                startContinuation = nil
                return
            }
            startContinuation?.resume()
            startContinuation = nil
        case let .failed(error):
            listener?.cancel()
            listener = nil
            startContinuation?.resume(throwing: CmxWebRTCSignalingError.connectionFailed(String(describing: error)))
            startContinuation = nil
        case .cancelled:
            startContinuation?.resume(throwing: CmxWebRTCSignalingError.closed)
            startContinuation = nil
        case .setup, .waiting:
            break
        @unknown default:
            break
        }
    }

    private func accept(connection: NWConnection) async {
        let signaling = CmxWebRTCSignalingConnection(connection: connection)
        do {
            try await signaling.start(timeoutNanoseconds: configuration.signalingTimeoutNanoseconds)
            guard case let .hello(receivedToken) = try await signaling.receive(),
                  receivedToken == token else {
                await signaling.close()
                return
            }
            let transport = CmxWebRTCByteTransport(
                hostSignaling: signaling,
                configuration: configuration
            )
            let id = UUID()
            activeTransports[id] = transport
            do {
                try await transport.startHostNegotiation()
                await transportHandler(transport)
            } catch {
                await transport.close()
                activeTransports.removeValue(forKey: id)
            }
        } catch {
            await signaling.close()
        }
    }
}

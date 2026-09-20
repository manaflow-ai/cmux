import CmuxRemoteWorkspace
import Foundation
import Network

/// The local, WKWebView-facing half of ssh-tmux's browser proxy: a loopback
/// `NWListener` that feeds every accepted connection into a
/// ``RemoteDaemonProxySession`` (the same SOCKS5/HTTP-CONNECT handshake
/// parser and loopback-alias HTTP rewriter `cmux ssh`'s daemon-backed proxy
/// uses), backed by a ``RemoteTmuxSocksProxyStreamClient`` that dials the
/// second hop out through ssh-tmux's `-D` dynamic forward.
///
/// Two distinct local ports are involved and must never be confused: this
/// listener's port is the one published to `BrowserPanel` (it does the HTTP
/// rewriting so Vite-style host-checking dev servers accept the request);
/// the `-D` forward's port is a private implementation detail only this
/// listener's sessions ever dial into. Never publish the `-D` port directly
/// — it has no HTTP awareness at all.
///
/// Isolation design mirrors `RemoteDaemonProxyTunnel`: every mutable property
/// is confined to the private serial `queue`. `@unchecked Sendable` because
/// `@Sendable` Network callbacks capture `self`; queue confinement is the
/// safety argument.
final class RemoteTmuxBrowserProxyListener: @unchecked Sendable {
    enum ListenerError: Error, LocalizedError {
        case invalidPort(Int)

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "invalid local browser proxy port \(port)"
            }
        }
    }

    private let localPort: Int
    private let dynamicForwardPort: Int
    private let queue = DispatchQueue(label: "com.cmuxterm.app.remote-tmux.browser-proxy-listener.\(UUID().uuidString)", qos: .utility)

    private var listener: NWListener?
    private var sessions: [UUID: RemoteDaemonProxySession] = [:]
    private var isStopped = false

    /// - Parameters:
    ///   - localPort: The loopback port this listener binds to; this is the
    ///     port published to `BrowserPanel`.
    ///   - dynamicForwardPort: The already-open `ssh -D` port every accepted
    ///     session's outgoing leg dials into.
    init(localPort: Int, dynamicForwardPort: Int) {
        self.localPort = localPort
        self.dynamicForwardPort = dynamicForwardPort
    }

    /// Binds the listener and waits for it to actually become ready; throws
    /// if the port is already taken (the registry retries with a fresh
    /// port on that failure) or if it's stopped before becoming ready.
    ///
    /// `NWListener.start(queue:)` is asynchronous — binding happens on
    /// `queue`, and a failure (e.g. the exact port-collision race the
    /// registry's retry loop exists to handle) only ever reaches
    /// `stateUpdateHandler`. Returning immediately without observing that
    /// would let a bind failure go completely unreported: the registry would
    /// think `start()` succeeded and publish an endpoint pointing at a
    /// listener that will never accept anything.
    func start() async throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(localPort)) else {
            throw ListenerError.invalidPort(localPort)
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: port)
        let listener = try NWListener(using: parameters)

        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.acceptConnectionLocked(connection)
            }
        }

        // `stateUpdateHandler` always fires serialized on `queue` (the
        // listener starts with `queue: queue` below), so `didResume` is safe
        // despite the plain capture, and `self.listener = listener` below is
        // properly queue-confined too.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didResume = false
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !didResume else { return }
                    didResume = true
                    guard self?.isStopped != true else {
                        listener.cancel()
                        continuation.resume(throwing: RemoteTmuxError.unreachable("browser proxy listener stopped before becoming ready"))
                        return
                    }
                    self?.listener = listener
                    continuation.resume()
                case .failed(let error):
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(throwing: RemoteTmuxError.unreachable("browser proxy listener cancelled before becoming ready"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            listener?.cancel()
            listener = nil
            for session in sessions.values {
                session.stop()
            }
            sessions.removeAll()
        }
    }

    private func acceptConnectionLocked(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        let streamClient = RemoteTmuxSocksProxyStreamClient(localForwardPort: dynamicForwardPort)
        let session = RemoteDaemonProxySession(
            connection: connection,
            rpcClient: streamClient,
            queue: queue
        ) { [weak self] id in
            self?.queue.async {
                self?.sessions.removeValue(forKey: id)
            }
        }
        sessions[session.id] = session
        session.start()
    }
}

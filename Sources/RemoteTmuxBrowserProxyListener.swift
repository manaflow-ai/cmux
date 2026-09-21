import CmuxRemoteWorkspace
import Foundation
import Network

/// The local, WKWebView-facing half of ssh-tmux's browser proxy: a loopback
/// `NWListener` that feeds every accepted connection into a
/// ``RemoteDaemonProxySessionHandling`` (built via
/// `makeRemoteDaemonProxySession`, the same SOCKS5/HTTP-CONNECT handshake
/// parser and loopback-alias HTTP rewriter `cmux ssh`'s daemon-backed proxy
/// uses — its concrete `RemoteDaemonProxySession` implementation is
/// intentionally not public), backed by a ``RemoteTmuxSocksProxyStreamClient``
/// that dials the second hop out through ssh-tmux's `-D` dynamic forward.
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
    /// Each session gets its own dedicated queue, distinct from this
    /// listener's `queue` — a session's SOCKS handshake/dial can block for
    /// several seconds on a slow or dead second hop, and that must never
    /// stall `queue`, which also drives `newConnectionHandler` for every
    /// other connection on this host. The queue is tracked alongside its
    /// session so `stop()` can dispatch each session's teardown onto the
    /// queue it actually owns, matching `RemoteDaemonProxySession`'s
    /// contract that callers are already confined to its `queue` before
    /// touching it.
    private var sessions: [UUID: (session: any RemoteDaemonProxySessionHandling, queue: DispatchQueue)] = [:]
    private var isStopped = false

    /// Fires at most once, on `queue`, if the listener fails or is cancelled
    /// unexpectedly *after* `start()` already returned successfully (e.g.
    /// the process hits its socket/file-descriptor limit). Never fired for
    /// `stop()`'s own, intentional cancellation. Set by the registry before
    /// calling `start()`, so it can republish a nil endpoint instead of
    /// leaving one parked pointing at a dead listener.
    var onUnexpectedFailure: ((Error) -> Void)?

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
                    // Startup is done — swap in the steady-state handler so a
                    // failure occurring *after* this method has already
                    // returned isn't silently swallowed by `guard !didResume`
                    // forever.
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self, !self.isStopped else { return }
                        switch state {
                        case .failed(let error):
                            self.onUnexpectedFailure?(error)
                        case .cancelled:
                            self.onUnexpectedFailure?(RemoteTmuxError.unreachable("browser proxy listener was cancelled"))
                        default:
                            break
                        }
                    }
                    continuation.resume()
                case .failed(let error):
                    guard !didResume else { return }
                    didResume = true
                    listener.cancel()
                    continuation.resume(throwing: error)
                case .waiting(let error):
                    // A loopback listener that parks in `.waiting` (its bound
                    // port taken out from under it, e.g.) never recovers on
                    // its own — treat it as terminal rather than letting the
                    // registry's `acquire()` task hang forever waiting for a
                    // `.ready` that will never come.
                    guard !didResume else { return }
                    didResume = true
                    listener.cancel()
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
            for (session, sessionQueue) in sessions.values {
                sessionQueue.async {
                    session.stop()
                }
            }
            sessions.removeAll()
        }
    }

    private func acceptConnectionLocked(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        let sessionQueue = DispatchQueue(label: "com.cmuxterm.app.remote-tmux.browser-proxy-session.\(UUID().uuidString)", qos: .utility)
        let streamClient = RemoteTmuxSocksProxyStreamClient(localForwardPort: dynamicForwardPort)
        let session = makeRemoteDaemonProxySession(
            connection: connection,
            rpcClient: streamClient,
            queue: sessionQueue
        ) { [weak self] id in
            self?.queue.async {
                self?.sessions.removeValue(forKey: id)
            }
        }
        sessions[session.id] = (session, sessionQueue)
        // On the session's own queue, not `queue` — see `sessions`.
        sessionQueue.async {
            session.start()
        }
    }
}

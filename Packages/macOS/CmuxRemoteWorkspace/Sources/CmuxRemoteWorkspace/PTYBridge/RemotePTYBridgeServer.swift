public import CmuxRemoteDaemon
internal import Foundation
import Network

/// Single-use loopback TCP server bridging one local PTY client (the cmux
/// CLI) to one remote daemon PTY attachment: it listens on `127.0.0.1`,
/// accepts exactly one connection, validates a JSON handshake line carrying
/// the bridge token, then attaches over the daemon RPC client and pumps
/// bytes both ways (faithful lift of the legacy
/// `WorkspaceRemotePTYBridgeServer`; renamed, no runtime strings mention the
/// type name).
///
/// Wire behavior is pinned: the newline-delimited JSON handshake (token,
/// cols/rows, client_pid), the `{"type":"ready","attachment_token":...}` and
/// `{"type":"error","message":...}` status lines (plus optional error
/// `code`), every buffer cap, the 30s handshake and unused-bridge timeouts,
/// the half-close semantics, and the error-message mapping in
/// `userFacingBridgeErrorMessage` must not change.
///
/// Isolation design: every mutable property (listener, session, isStopped,
/// and all Session state) is confined to the private serial `queue`.
/// Mutators are `start()` (caller thread, blocking on the listener-ready
/// semaphore exactly like the legacy code), Network framework callbacks
/// (started on `queue`), RPC completions (hopped onto `queue`), and the
/// clock-driven timeout tasks (hopped onto `queue`). `@unchecked Sendable`
/// because `@Sendable` Network/RPC/Task callbacks capture `self`; queue
/// confinement is the safety argument. Async/await migration of the bridge
/// is a deliberate later-phase item (plan: "Modernization hot-spots").
public final class RemotePTYBridgeServer: @unchecked Sendable {
    static let unusedBridgeTimeoutMilliseconds = 30_000

    /// Where a PTY client should connect, and what it must present.
    public struct Endpoint: Sendable {
        /// Loopback host the bridge listens on (always `127.0.0.1`).
        public let host: String
        /// Bound TCP port.
        public let port: Int
        /// One-time token the client must echo in the handshake line.
        public let token: String
        /// Remote persistent PTY session this bridge attaches to.
        public let sessionID: String
        /// Attachment identifier requested for this bridge.
        public let attachmentID: String
    }

    private let rpcClient: any RemotePTYBridgeRPCClient
    private let sessionID: String
    private let attachmentID: String
    private let command: String?
    private let requireExisting: Bool
    private let strings: any RemotePTYBridgeStrings
    private let clock: any RemoteProxyRetryClock
    private let token = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.pty-bridge.\(UUID().uuidString)", qos: .userInitiated)
    private let onStop: () -> Void

    private var listener: NWListener?
    private var session: Session?
    private var isStopped = false
    private var unusedBridgeTimeoutTask: Task<Void, Never>?

    /// Creates a bridge server for one remote PTY attachment.
    ///
    /// - Parameters:
    ///   - rpcClient: Daemon RPC seam used to attach/write/detach.
    ///   - sessionID: Remote persistent PTY session identifier.
    ///   - attachmentID: Attachment identifier to request.
    ///   - command: Optional command to start when the session does not
    ///     exist yet.
    ///   - requireExisting: When true, the attach fails unless the session
    ///     already exists.
    ///   - strings: App-resolved attach-failure strings (localization stays
    ///     app-side).
    ///   - clock: Sleep seam driving the handshake and unused-bridge
    ///     timeouts (virtual time in tests).
    ///   - onStop: Invoked exactly once, on the bridge queue, when the
    ///     bridge stops for any reason.
    public init(
        rpcClient: any RemotePTYBridgeRPCClient,
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool,
        strings: any RemotePTYBridgeStrings,
        clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock(),
        onStop: @escaping () -> Void
    ) {
        self.rpcClient = rpcClient
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.command = command
        self.requireExisting = requireExisting
        self.strings = strings
        self.clock = clock
        self.onStop = onStop
    }

    /// Starts the loopback listener and returns its endpoint, blocking the
    /// caller until the listener is ready (5s cap, legacy contract).
    public func start() throws -> Endpoint {
        let listener = try Self.makeLoopbackListener()
        let readySemaphore = DispatchSemaphore(value: 0)
        let startupState = ListenerStartupState()

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.queue.async {
                self.acceptConnectionLocked(connection)
            }
        }
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready:
                startupState.recordReady(port: listener?.port.map { Int($0.rawValue) })
                readySemaphore.signal()
            case .failed(let error):
                startupState.recordFailure(error)
                readySemaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        guard readySemaphore.wait(timeout: .now() + 5.0) == .success else {
            listener.cancel()
            throw NSError(domain: "cmux.remote.pty", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "timed out waiting for PTY bridge listener",
            ])
        }
        let outcome = startupState.snapshot()
        if let startupError = outcome.failure {
            listener.cancel()
            throw startupError
        }
        guard let startupPort = outcome.port, startupPort > 0 else {
            listener.cancel()
            throw NSError(domain: "cmux.remote.pty", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "failed to bind PTY bridge listener",
            ])
        }

        self.listener = listener
        queue.async { [weak self] in
            self?.armUnusedBridgeTimeoutLocked()
        }
        return Endpoint(
            host: "127.0.0.1",
            port: startupPort,
            token: token,
            sessionID: sessionID,
            attachmentID: attachmentID
        )
    }

    /// Stops the listener and any active session; safe to call repeatedly.
    public func stop() {
        queue.async {
            self.stopLocked()
        }
    }

    private func acceptConnectionLocked(_ connection: NWConnection) {
        guard !isStopped, session == nil else {
            connection.cancel()
            return
        }
        unusedBridgeTimeoutTask?.cancel()
        unusedBridgeTimeoutTask = nil
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil

        let session = Session(
            connection: connection,
            rpcClient: rpcClient,
            sessionID: sessionID,
            attachmentID: attachmentID,
            command: command,
            requireExisting: requireExisting,
            token: token,
            queue: queue,
            strings: strings,
            clock: clock
        ) { [weak self] in
            self?.stopLocked()
        }
        self.session = session
        session.start()
    }

    private func armUnusedBridgeTimeoutLocked() {
        guard !isStopped, listener != nil, session == nil else { return }
        // Bounded, cancellable timeout via the injected clock (legacy used
        // queue.asyncAfter); the stopLocked guard absorbs stale fires.
        unusedBridgeTimeoutTask = Task { [weak self, clock] in
            guard (try? await clock.sleep(forMilliseconds: Self.unusedBridgeTimeoutMilliseconds)) != nil else { return }
            guard let self else { return }
            self.queue.async {
                guard !self.isStopped, self.session == nil else { return }
                self.stopLocked()
            }
        }
    }

    private func stopLocked() {
        guard !isStopped else { return }
        isStopped = true
        unusedBridgeTimeoutTask?.cancel()
        unusedBridgeTimeoutTask = nil
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        let activeSession = session
        session = nil
        activeSession?.stop()
        onStop()
    }

    private static func makeLoopbackListener() throws -> NWListener {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        return try NWListener(using: parameters)
    }
}

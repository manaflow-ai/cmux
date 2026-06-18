public import CmuxCore
public import CmuxRemoteDaemon
internal import Foundation
import Network

/// Loopback SOCKS5/HTTP-CONNECT proxy tunnel for one remote workspace: owns a
/// `RemoteDaemonRPCClient`, a local `NWListener` bound to `127.0.0.1`, the
/// per-connection ``RemoteDaemonProxySession``s, and any
/// ``RemotePTYBridgeServer``s started through it.
///
/// Faithful lift of the legacy `WorkspaceRemoteDaemonProxyTunnel` (renamed;
/// no runtime strings mention the type name).
///
/// Isolation design: every mutable property is confined to the private
/// serial `queue`. Mutators are `start()`/`stop()`/the PTY helpers (caller
/// threads bridged with the legacy blocking `queue.sync`, load-bearing
/// because callers need synchronous results), listener callbacks (started on
/// `queue`), and RPC-client failure callbacks (hopped onto `queue`). The
/// blocking sync sections preserve legacy ordering; an actor would make the
/// synchronous `listPTY`/`startPTYBridge` contracts impossible without
/// semaphores. `@unchecked Sendable` because `@Sendable` Network/RPC
/// callbacks capture `self`; queue confinement is the safety argument.
public final class RemoteDaemonProxyTunnel: @unchecked Sendable {
    private let configuration: WorkspaceRemoteConfiguration
    private let remotePath: String
    private let localPort: Int
    private let strings: RemoteDaemonStrings
    private let ptyBridgeStrings: any RemotePTYBridgeStrings
    private let clock: any RemoteProxyRetryClock
    private let onFatalError: (String) -> Void
    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-tunnel.\(UUID().uuidString)", qos: .utility)

    private var listener: NWListener?
    private var rpcClient: RemoteDaemonRPCClient?
    private var sessions: [UUID: RemoteDaemonProxySession] = [:]
    private var ptyBridgeServers: [UUID: RemotePTYBridgeServer] = [:]
    private var isStopped = false

    /// Creates a tunnel for `configuration`.
    ///
    /// - Parameters:
    ///   - remotePath: Resolved remote path of the daemon binary.
    ///   - localPort: Loopback port to bind the proxy listener to.
    ///   - strings: App-resolved daemon error strings, passed through to the
    ///     RPC client (localization stays app-side).
    ///   - ptyBridgeStrings: App-resolved PTY attach error strings, passed
    ///     through to PTY bridge servers.
    ///   - clock: Sleep seam forwarded to PTY bridge servers' timeouts.
    ///   - onFatalError: Invoked (off the main queue, on the tunnel queue)
    ///     once when the tunnel fails irrecoverably; the tunnel has already
    ///     stopped itself.
    public init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        strings: RemoteDaemonStrings,
        ptyBridgeStrings: any RemotePTYBridgeStrings,
        clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock(),
        onFatalError: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.localPort = localPort
        self.strings = strings
        self.ptyBridgeStrings = ptyBridgeStrings
        self.clock = clock
        self.onFatalError = onFatalError
    }

    /// Starts the RPC client and the loopback listener; throws when either
    /// fails (the tunnel is then stopped and unusable).
    public func start() throws {
        var capturedError: (any Error)?
        queue.sync {
            guard !isStopped else {
                capturedError = NSError(domain: "cmux.remote.proxy", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "proxy tunnel already stopped",
                ])
                return
            }
            do {
                let client = RemoteDaemonRPCClient(
                    configuration: configuration,
                    remotePath: remotePath,
                    strings: strings
                ) { [weak self] detail in
                    guard let self else { return }
                    self.queue.async {
                        self.failLocked("Remote daemon transport failed: \(detail)")
                    }
                }
                try client.start()

                let listener = try Self.makeLoopbackListener(port: localPort)
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    self.queue.async {
                        self.acceptConnectionLocked(connection)
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    self.queue.async {
                        self.handleListenerStateLocked(state)
                    }
                }

                self.rpcClient = client
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                capturedError = error
                stopLocked(notify: false)
            }
        }
        if let capturedError {
            throw capturedError
        }
    }

    /// Stops the listener, all sessions, all PTY bridges, and the RPC client.
    public func stop() {
        queue.sync {
            stopLocked(notify: false)
        }
    }

    /// Lists the daemon's persistent PTY sessions.
    ///
    /// Wire shape: array of JSON objects straight from the daemon; stays
    /// `[[String: Any]]` to match the legacy payload plumbing.
    public func listPTY() throws -> [[String: Any]] {
        try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.pty", code: 30, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            return try rpcClient.listPTY()
        }
    }

    /// Closes a persistent PTY session on the daemon.
    public func closePTY(sessionID: String) throws {
        try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.pty", code: 31, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            try rpcClient.closePTY(sessionID: sessionID)
        }
    }

    /// Resizes a PTY attachment.
    public func resizePTY(sessionID: String, attachmentID: String, attachmentToken: String, cols: Int, rows: Int) throws {
        try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.pty", code: 32, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            try rpcClient.resizePTY(
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken,
                cols: cols,
                rows: rows
            )
        }
    }

    /// Detaches a PTY attachment, surfacing daemon-side errors.
    public func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) throws {
        try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.pty", code: 34, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            try rpcClient.detachPTYChecked(
                sessionID: sessionID,
                attachmentID: attachmentID,
                attachmentToken: attachmentToken
            )
        }
    }

    /// Starts a single-use loopback PTY bridge server for a terminal attach
    /// and returns its endpoint.
    public func startPTYBridge(sessionID: String, attachmentID: String, command: String?, requireExisting: Bool) throws -> RemotePTYBridgeServer.Endpoint {
        try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.pty", code: 33, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            let bridgeID = UUID()
            let server = RemotePTYBridgeServer(
                rpcClient: rpcClient,
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting,
                strings: ptyBridgeStrings,
                clock: clock
            ) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.ptyBridgeServers.removeValue(forKey: bridgeID)
                }
            }
            let endpoint = try server.start()
            ptyBridgeServers[bridgeID] = server
            return endpoint
        }
    }

    private func handleListenerStateLocked(_ state: NWListener.State) {
        guard !isStopped else { return }
        switch state {
        case .failed(let error):
            failLocked("Local proxy listener failed: \(error)")
        default:
            break
        }
    }

    private func acceptConnectionLocked(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        guard let rpcClient else {
            connection.cancel()
            return
        }

        let session = RemoteDaemonProxySession(
            connection: connection,
            rpcClient: rpcClient,
            queue: queue
        ) { [weak self] id in
            guard let self else { return }
            self.queue.async {
                self.sessions.removeValue(forKey: id)
            }
        }
        sessions[session.id] = session
        session.start()
    }

    private func failLocked(_ detail: String) {
        guard !isStopped else { return }
        stopLocked(notify: false)
        onFatalError(detail)
    }

    private func stopLocked(notify: Bool) {
        guard !isStopped else { return }
        isStopped = true

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        let activeSessions = sessions.values
        sessions.removeAll()
        for session in activeSessions {
            session.stop()
        }
        let activePTYBridges = ptyBridgeServers.values
        ptyBridgeServers.removeAll()
        for bridge in activePTYBridges {
            bridge.stop()
        }

        rpcClient?.stop()
        rpcClient = nil
    }

    private static func makeLoopbackListener(port: Int) throws -> NWListener {
        guard let localPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "cmux.remote.proxy", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "invalid local proxy port \(port)",
            ])
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: localPort)
        return try NWListener(using: parameters)
    }
}

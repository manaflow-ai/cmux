public import Foundation
import Network

/// Loopback TCP relay that lets the remote host's `cmux` CLI reach the local
/// cmux control socket: it listens on `127.0.0.1`, authenticates each
/// connection with an HMAC challenge over the relay token, rewrites
/// workspace/surface ID aliases in the forwarded command line, round-trips
/// the command against the local unix socket, and returns the response
/// (faithful lift of the legacy `WorkspaceRemoteCLIRelayServer`; renamed, no
/// runtime strings mention the type name).
///
/// Wire behavior is pinned: the `cmux-relay-auth` challenge JSON (protocol,
/// version, relay_id, nonce), HMAC-SHA256 over the exact auth message bytes,
/// the `{"ok":true}` / `{"ok":false}` newline-framed responses, the 16 KiB
/// frame cap, the constant-time MAC comparison, the 50ms minimum
/// failure-response delay (anti-timing-oracle), and every NSError
/// domain/code/message must not change.
///
/// Isolation design: all mutable state (listener, sessions, aliases,
/// localPort, per-session phase/buffer) is confined to the private serial
/// `queue`. Mutators are `start()`/`stop()` (caller thread, blocking on the
/// listener-ready semaphore exactly like the legacy code), Network framework
/// callbacks (started on `queue`), the blocking unix-socket round trip
/// (runs on a global utility queue, hops back), and the clock-driven failure
/// delay (hops back). `@unchecked Sendable` because `@Sendable`
/// Network/Task callbacks capture `self`; queue confinement is the safety
/// argument. The actor/async migration is a deliberate later-phase item
/// (plan: "Modernization hot-spots").
public final class RemoteCLIRelayServer: @unchecked Sendable {
    private let localSocketPath: String
    private let relayID: String
    private let relayToken: Data
    private let commandRewriter: any RemoteRelayCommandRewriting
    private let clock: any RemoteProxyRetryClock
    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.cli-relay.\(UUID().uuidString)", qos: .utility)

    private var listener: NWListener?
    private var sessions: [UUID: Session] = [:]
    private var isStopped = false
    private var localPort: Int?
    private var workspaceAliases: [UUID: UUID] = [:]
    private var surfaceAliases: [UUID: UUID] = [:]

    /// Creates a relay for one remote connection.
    ///
    /// - Parameters:
    ///   - localSocketPath: Path of the local cmux control unix socket.
    ///   - relayID: Public identifier echoed in the auth challenge.
    ///   - relayTokenHex: Hex-encoded shared secret; throws
    ///     `cmux.remote.relay` code 7 when invalid or empty.
    ///   - commandRewriter: Alias-aware command rewrite seam (the app's
    ///     workspace model conforms).
    ///   - clock: Sleep seam for the minimum failure-response delay
    ///     (virtual time in tests).
    public init(
        localSocketPath: String,
        relayID: String,
        relayTokenHex: String,
        commandRewriter: any RemoteRelayCommandRewriting,
        clock: any RemoteProxyRetryClock = SystemRemoteProxyRetryClock()
    ) throws {
        guard let relayToken = Session.hexData(from: relayTokenHex), !relayToken.isEmpty else {
            throw NSError(domain: "cmux.remote.relay", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "invalid relay token",
            ])
        }
        self.localSocketPath = localSocketPath
        self.relayID = relayID
        self.relayToken = relayToken
        self.commandRewriter = commandRewriter
        self.clock = clock
    }

    /// Starts the loopback listener (idempotent) and returns its bound port,
    /// blocking the caller until the listener is ready (5s cap, legacy
    /// contract).
    public func start() throws -> Int {
        if let existingPort = queue.sync(execute: { localPort }) {
            return existingPort
        }

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
        listener.stateUpdateHandler = { [weak listener] listenerState in
            switch listenerState {
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

        let waitResult = readySemaphore.wait(timeout: .now() + 5.0)
        let outcome = startupState.snapshot()

        if waitResult != .success {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw NSError(domain: "cmux.remote.relay", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "timed out waiting for local relay listener",
            ])
        }
        if let startupError = outcome.failure {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw startupError
        }
        guard let startupPort = outcome.port, startupPort > 0 else {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            throw NSError(domain: "cmux.remote.relay", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "failed to bind local relay listener",
            ])
        }

        return queue.sync {
            if let localPort {
                listener.newConnectionHandler = nil
                listener.stateUpdateHandler = nil
                listener.cancel()
                return localPort
            }
            self.listener = listener
            self.localPort = startupPort
            return startupPort
        }
    }

    /// Stops the listener and all sessions; safe to call repeatedly.
    public func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            listener?.newConnectionHandler = nil
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil
            localPort = nil
            let activeSessions = sessions.values
            sessions.removeAll()
            for session in activeSessions {
                session.stop()
            }
        }
    }

    /// Replaces the workspace/surface ID alias maps used to rewrite
    /// forwarded command lines.
    public func updateRemoteRelayIDAliases(workspaceAliases: [UUID: UUID], surfaceAliases: [UUID: UUID]) {
        queue.async { [weak self] in
            self?.workspaceAliases = workspaceAliases
            self?.surfaceAliases = surfaceAliases
        }
    }

    private func acceptConnectionLocked(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        let sessionID = UUID()
        let session = Session(
            connection: connection,
            localSocketPath: localSocketPath,
            relayID: relayID,
            relayToken: relayToken,
            commandRewriter: { [weak self] commandLine in
                self?.rewriteCommandLineLocked(commandLine) ?? commandLine
            },
            queue: queue,
            clock: clock
        ) { [weak self] in
            self?.sessions.removeValue(forKey: sessionID)
        }
        sessions[sessionID] = session
        session.start()
    }

    private func rewriteCommandLineLocked(_ commandLine: Data) -> Data {
        commandRewriter.rewriteRemoteRelayCommandLine(
            commandLine,
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases
        )
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

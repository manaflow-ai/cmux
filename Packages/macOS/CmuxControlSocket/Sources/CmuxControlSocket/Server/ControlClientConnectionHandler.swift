public import CmuxSettings
public import Darwin
internal import Foundation

/// Drives one accepted control-socket connection end to end: the `cmuxOnly`
/// access-control gate, the password-authentication handshake (for the
/// `events.stream` branch), the newline-framed read loop, and the response
/// write. Lifted byte-faithfully from `TerminalController.handleClient` and its
/// `writeSocketResponse` helper.
///
/// The handler owns the transport pipeline only. Command bodies — the
/// `events.stream` subscription and the v1/v2 command switch — reach into live
/// application state, so they cross the ``ControlClientCommandDispatching``
/// seam back to the composition root, exactly where the legacy loop called
/// `isEventsStreamRequest` / `handleEventsStreamRequest` / `processSocketLine`
/// / `publishSocketEvents`. The password handshake itself is the shared
/// ``ControlPasswordAuthenticator`` (the legacy `authResponseIfNeeded` family),
/// used here for the events-stream gate and by the dispatcher's command path.
///
/// ## Isolation design
///
/// One instance serves one connection on one dedicated handler thread
/// (``spawnDetached(_:)`` matches the legacy `Thread.detachNewThread`); the
/// type is `nonisolated` and intentionally not concurrency-safe across
/// threads. The blocking read loop and the per-command dispatch must never run
/// on the cooperative pool — the command bodies block — so the handler is a
/// plain reference type driven from a detached `Thread`, never an actor or a
/// `Task`. `isRunning` is the listener's published-snapshot poll, captured as a
/// `@Sendable` closure so the handler does not retain the server.
///
/// ## Live access-mode reads (faithful to `handleClient`)
///
/// The listener's access mode can change on a live, already-running listener
/// without tearing down accepted connections: a Settings toggle of the socket
/// control mode keeps the same socket path, so `SocketControlServer.start`
/// updates `state.accessMode` in place and early-returns without `stop()`, and
/// `stop()` does not close per-connection sockets or join the detached handler
/// threads. The legacy `handleClient` therefore read `socketServer.accessMode`
/// LIVE: the `cmuxOnly` ancestry gate at the top of the loop, and the
/// `events.stream` password gate via `authResponseIfNeeded` (which read
/// `accessMode.requiresPasswordAuth`) at the moment the line was read. To match
/// that exactly under a mid-connection mode toggle, ``accessMode`` and
/// ``makeAuthenticator`` are `@Sendable` closures that read the listener's live
/// snapshot, not values frozen at connection spawn — mirroring how the command
/// path rebuilds a fresh ``ControlPasswordAuthenticator`` per line. Capturing
/// either once would let a connection that opened in `cmuxOnly` (no password)
/// keep serving `events.stream` unauthenticated after the user switched the
/// running listener to password mode, a security-direction regression the
/// command path never had.
///
/// `@unchecked Sendable` is limited to the handoff into `Thread.detachNewThread`:
/// the instance is fully initialized first, then owned by that one handler
/// thread for the rest of its lifetime.
public final class ControlClientConnectionHandler: @unchecked Sendable {
    private let socket: Int32
    private let peerProcessID: pid_t?
    private let transport: SocketTransport
    private let accessMode: @Sendable () -> SocketControlMode
    private let selfProcessID: pid_t
    private let isRunning: @Sendable () -> Bool
    private let makeAuthenticator: @Sendable () -> ControlPasswordAuthenticator
    private let dispatcher: any ControlClientCommandDispatching

    /// Creates a handler for one accepted connection.
    /// - Parameters:
    ///   - socket: The accepted client descriptor; closed when ``run()``
    ///     returns (the legacy `defer { close(socket) }`).
    ///   - peerProcessID: The peer PID captured at accept time, or `nil` when
    ///     `LOCAL_PEERPID` failed (peer disconnected before the read).
    ///   - transport: Stateless syscall surface for peer checks and the write.
    ///   - accessMode: Reads the listener's live access mode; the `cmuxOnly`
    ///     ancestry gate evaluates it when the connection starts, matching
    ///     `handleClient`'s live `socketServer.accessMode` read.
    ///   - selfProcessID: This process's PID, the ancestry root (`getpid()`).
    ///   - isRunning: Polled before each blocking read, the listener's
    ///     `isRunning` snapshot in production.
    ///   - makeAuthenticator: Builds the shared password handshake against the
    ///     listener's live access mode; invoked fresh per `events.stream` line
    ///     so the gate tracks a mid-connection mode toggle exactly as the
    ///     dispatcher's command path does (which rebuilds it per line).
    ///   - dispatcher: The app-coupled command-dispatch seam.
    public init(
        socket: Int32,
        peerProcessID: pid_t?,
        transport: SocketTransport,
        accessMode: @escaping @Sendable () -> SocketControlMode,
        selfProcessID: pid_t,
        isRunning: @escaping @Sendable () -> Bool,
        makeAuthenticator: @escaping @Sendable () -> ControlPasswordAuthenticator,
        dispatcher: any ControlClientCommandDispatching
    ) {
        self.socket = socket
        self.peerProcessID = peerProcessID
        self.transport = transport
        self.accessMode = accessMode
        self.selfProcessID = selfProcessID
        self.isRunning = isRunning
        self.makeAuthenticator = makeAuthenticator
        self.dispatcher = dispatcher
    }

    /// Spawns a detached handler thread that runs `handler.run()`, then closes
    /// the descriptor. Matches the legacy `spawnClientHandler`: accepts never
    /// funnel through the cooperative pool because command bodies block.
    /// - Parameter handler: The connection handler to drive.
    public static func spawnDetached(_ handler: ControlClientConnectionHandler) {
        Thread.detachNewThread {
            handler.run()
        }
    }

    /// Runs the connection: access-control gate, then the authenticated
    /// read/dispatch/write loop. Closes the descriptor on return.
    public func run() {
        defer { close(socket) }

        // In cmuxOnly mode, verify the connecting process is a descendant of cmux.
        // In allowAll mode (env-var only), skip the ancestry check.
        // Read the listener's live access mode (the legacy `handleClient` read
        // `socketServer.accessMode` here, not a value frozen at accept time).
        if accessMode() == .cmuxOnly {
            // Use pre-captured peer PID if available (captured in accept loop before
            // the peer can disconnect), falling back to live lookup.
            let pid = peerProcessID ?? transport.peerProcessID(of: socket)
            guard SocketClientAuthorization().isCmuxOnlyClientAllowed(
                peerProcessID: pid,
                peerHasSameUID: false,
                isDescendant: { [transport, selfProcessID] in
                    transport.isProcessDescendant($0, of: selfProcessID)
                }
            ) else {
                _ = writeSocketResponse(
                    pid == nil
                        ? "ERROR: Unable to verify client process"
                        : "ERROR: Access denied — only processes started inside cmux can connect",
                    to: socket
                )
                return
            }
        }

        var authenticated = false
        let lineReader = ControlClientLineReader(socket: socket)

        while let line = lineReader.nextLine(shouldContinueReading: { self.isRunning() }) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            var shouldCloseSocket = false
            autoreleasepool {
                if dispatcher.isEventsStreamRequest(trimmed) {
                    // Build the authenticator against the listener's LIVE access
                    // mode for this line, matching `handleClient`'s per-line
                    // `authResponseIfNeeded` (and the command path's per-line
                    // `passwordAuthenticator()`). A mode toggle on the running
                    // listener mid-connection therefore tightens (or relaxes)
                    // this gate exactly as legacy did.
                    let decision = makeAuthenticator().response(for: trimmed, authenticated: authenticated)
                    authenticated = decision.authenticated
                    if let response = decision.response {
                        if !writeSocketResponse(response, to: socket) {
                            shouldCloseSocket = true
                        }
                        return
                    }
                    dispatcher.handleEventsStream(line: trimmed, socket: socket)
                    shouldCloseSocket = true
                    return
                }

                let result = dispatcher.processCommandLine(trimmed, authenticated: authenticated)
                authenticated = result.authenticated
                if let response = result.response {
                    let didWriteResponse = writeSocketResponse(response, to: socket)
                    dispatcher.publishCommandEvents(command: trimmed, response: response)
                    if !didWriteResponse {
                        shouldCloseSocket = true
                    }
                }
            }
            if shouldCloseSocket {
                return
            }
        }
    }

    private func writeSocketResponse(_ response: String, to socket: Int32) -> Bool {
        let payload = response + "\n"
        return transport.writeAll(Data(payload.utf8), to: socket)
    }
}

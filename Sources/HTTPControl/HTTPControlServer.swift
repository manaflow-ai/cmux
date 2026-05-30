import Foundation
import Network

/// Local-only HTTP control transport for the cmux terminal-access API.
///
/// Binds 127.0.0.1 (TCP, D11/D12) using `Network.framework`'s
/// ``NWListener`` with `requiredInterfaceType = .loopback`. A future
/// task wires UDS support (D12) via a sibling listener; this class is
/// the TCP bring-up.
///
/// Routes are registered via ``RouteTable`` and dispatched per request.
/// Auth, Host allowlist and body-cap rejection happen here BEFORE
/// route dispatch.
public final class HTTPControlServer: @unchecked Sendable {
    /// Factory that builds a ``HostAllowlist`` for the actually bound
    /// port. Created lazily because `startTCP(port: 0)` returns the
    /// real port only after binding.
    public typealias HostAllowlistFactory = @Sendable (UInt16) -> HostAllowlist

    /// E11 — `isEnabled` is read atomically on every request inside
    /// ``handle(_:connection:)``. Lifecycle stops the listener on
    /// toggle-off; this closure handles in-flight requests during the
    /// stop and any races where settings flip false mid-connection.
    public typealias EnabledProbe = @Sendable () -> Bool

    let routeTable: RouteTable
    let auth: HTTPAuth
    let hostAllowlistFor: HostAllowlistFactory
    let isEnabled: EnabledProbe

    private let lock = NSLock()
    private var tcpListener: NWListener?
    private var udsListener: HTTPControlUDSListener?
    private let queue = DispatchQueue(
        label: "cmux.http-control",
        qos: .userInitiated
    )
    private var _boundPort: UInt16 = 0

    /// TCP port the listener bound to. Zero before ``startTCP(port:)``
    /// returns; reset to zero on ``stop()``.
    public var boundPort: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return _boundPort
    }

    /// Builds the server.
    ///
    /// - Parameters:
    ///   - routeTable: Pre-built route table (Task 1.10).
    ///   - auth: Bearer-token checker (Task 1.3).
    ///   - hostAllowlistFor: Factory closure that builds a
    ///     ``HostAllowlist`` for the bound port (Task 1.4).
    ///   - isEnabled: E11 — runtime kill switch consulted on every
    ///     request. Defaults to `{ true }` so legacy unit tests don't
    ///     need to pass settings.
    public init(
        routeTable: RouteTable,
        auth: HTTPAuth,
        hostAllowlistFor: @escaping HostAllowlistFactory,
        isEnabled: @escaping EnabledProbe = { true }
    ) {
        self.routeTable = routeTable
        self.auth = auth
        self.hostAllowlistFor = hostAllowlistFor
        self.isEnabled = isEnabled
    }

    /// Binds a loopback-only TCP listener. Pass `0` for an ephemeral
    /// port; the actually bound port is returned and also exposed via
    /// ``boundPort``.
    ///
    /// - Throws: Any error thrown by ``NWListener/init(using:on:)``.
    /// - Returns: The bound TCP port.
    @discardableResult
    public func startTCP(port: UInt16) throws -> UInt16 {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredInterfaceType = .loopback
        let endpoint = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: params, on: endpoint)
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        let resolved = listener.port?.rawValue ?? port
        lock.lock()
        self.tcpListener = listener
        self._boundPort = resolved
        lock.unlock()
        return resolved
    }

    /// Binds an AF_UNIX listener at `path`. Mode `0600`. D12 — uses
    /// the POSIX path through ``HTTPControlUDSListener`` rather than
    /// `NWEndpoint.unix(path:)`.
    ///
    /// The same route dispatch, auth, and body cap as the TCP path
    /// apply; the `Host` header check is short-circuited (UDS has no
    /// Host concept) and replaced by the file-permission check.
    public func startUDS(path: String) throws {
        let listener = HTTPControlUDSListener(
            path: path,
            queue: queue
        ) { [weak self] cfd in
            guard let self else { Darwin.close(cfd); return }
            self.acceptRawFD(cfd)
        }
        try listener.start()
        lock.lock()
        self.udsListener = listener
        lock.unlock()
    }

    /// Stops the listener and cancels any pending accepts.
    public func stop() {
        lock.lock()
        let l = tcpListener
        let u = udsListener
        tcpListener = nil
        udsListener = nil
        _boundPort = 0
        lock.unlock()
        l?.cancel()
        u?.stop()
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        let state = ConnectionState()
        read(conn: conn, state: state)
    }

    private final class ConnectionState: @unchecked Sendable {
        var parser = HTTPRequestParser(
            maxHeaderBytes: 16 * 1024,
            maxBodyBytes: 1 << 20
        )
    }

    private func read(conn: NWConnection, state: ConnectionState) {
        conn.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isEnd, _ in
            guard let self else { return }
            if let data { state.parser.feed(data) }
            do {
                switch try state.parser.next() {
                case .complete(let req):
                    Task { await self.handle(req, connection: conn) }
                case .need:
                    if isEnd {
                        conn.cancel()
                    } else {
                        self.read(conn: conn, state: state)
                    }
                }
            } catch HTTPParseError.bodyTooLarge,
                    HTTPParseError.headerTooLarge {
                self.write(
                    JSONResponses.error(.payloadTooLarge),
                    to: conn,
                    close: true
                )
            } catch {
                self.write(
                    JSONResponses.error(
                        .badRequest(reason: "malformed request")
                    ),
                    to: conn,
                    close: true
                )
            }
        }
    }

    private func handle(_ req: HTTPRequest, connection: NWConnection) async {
        // E11 — runtime-disabled check happens on every request.
        guard isEnabled() else {
            write(
                JSONResponses.error(.featureDisabled),
                to: connection,
                close: true
            )
            return
        }
        let port = boundPort
        let allowlist = hostAllowlistFor(port)
        switch allowlist.evaluate(
            host: req.header("host"),
            origin: req.header("origin")
        ) {
        case .missingHost:
            write(
                JSONResponses.error(.badRequest(reason: "missing Host")),
                to: connection,
                close: true
            )
            return
        case .forbiddenHost:
            write(
                JSONResponses.error(.forbidden(reason: "host not allowed")),
                to: connection,
                close: true
            )
            return
        case .forbiddenOrigin:
            write(
                JSONResponses.error(.forbidden(reason: "origin not allowed")),
                to: connection,
                close: true
            )
            return
        case .ok:
            break
        }
        if auth.evaluate(authorizationHeader: req.header("authorization")) != .ok {
            write(
                JSONResponses.error(.unauthorized),
                to: connection,
                close: true
            )
            return
        }
        let resp = await routeTable.dispatch(req)
        write(resp, to: connection, close: true)
    }

    private func write(
        _ resp: JSONResponses.Response,
        to conn: NWConnection,
        close: Bool
    ) {
        var head = "HTTP/1.1 \(resp.status) \(Self.reasonPhrase(resp.status))\r\n"
        for (k, v) in resp.headers { head += "\(k): \(v)\r\n" }
        if close { head += "Connection: close\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(resp.body)
        conn.send(content: data, completion: .contentProcessed { _ in
            if close { conn.cancel() }
        })
    }

    // MARK: - UDS accept path

    /// Wraps an accepted UDS client fd in `DispatchIO`, parses one
    /// request, dispatches it through the route table, and writes
    /// the response. Mirrors ``handle(_:connection:)`` for TCP; the
    /// UDS path uses port `0` for the Host allowlist (clients send
    /// `localhost:0`).
    private func acceptRawFD(_ fd: Int32) {
        let io = DispatchIO(
            type: .stream,
            fileDescriptor: fd,
            queue: queue,
            cleanupHandler: { _ in Darwin.close(fd) }
        )
        io.setLimit(lowWater: 1)
        let state = ConnectionState()
        readUDS(io: io, state: state)
    }

    private func readUDS(io: DispatchIO, state: ConnectionState) {
        io.read(offset: 0, length: 64 * 1024, queue: queue) { [weak self] _, data, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                state.parser.feed(Data(data))
                do {
                    switch try state.parser.next() {
                    case .complete(let req):
                        Task { await self.handleUDS(req, io: io) }
                        return
                    case .need:
                        self.readUDS(io: io, state: state)
                    }
                } catch HTTPParseError.bodyTooLarge,
                        HTTPParseError.headerTooLarge {
                    self.writeUDS(
                        JSONResponses.error(.payloadTooLarge),
                        io: io
                    )
                } catch {
                    self.writeUDS(
                        JSONResponses.error(
                            .badRequest(reason: "malformed request")
                        ),
                        io: io
                    )
                }
            } else {
                // EOF or read error — close the fd via DispatchIO cleanup.
                io.close(flags: .stop)
            }
        }
    }

    private func handleUDS(_ req: HTTPRequest, io: DispatchIO) async {
        guard isEnabled() else {
            writeUDS(JSONResponses.error(.featureDisabled), io: io)
            return
        }
        // UDS has no real Host concept, but the parser still required
        // an HTTP/1.1 Host header. We synthesise port 0 for the
        // allowlist and let clients send `Host: localhost:0` or
        // `Host: 127.0.0.1:0`.
        let allowlist = hostAllowlistFor(0)
        switch allowlist.evaluate(
            host: req.header("host"),
            origin: req.header("origin")
        ) {
        case .missingHost:
            writeUDS(
                JSONResponses.error(.badRequest(reason: "missing Host")),
                io: io
            )
            return
        case .forbiddenHost:
            writeUDS(
                JSONResponses.error(.forbidden(reason: "host not allowed")),
                io: io
            )
            return
        case .forbiddenOrigin:
            writeUDS(
                JSONResponses.error(.forbidden(reason: "origin not allowed")),
                io: io
            )
            return
        case .ok:
            break
        }
        if auth.evaluate(authorizationHeader: req.header("authorization")) != .ok {
            writeUDS(JSONResponses.error(.unauthorized), io: io)
            return
        }
        let resp = await routeTable.dispatch(req)
        writeUDS(resp, io: io)
    }

    private func writeUDS(_ resp: JSONResponses.Response, io: DispatchIO) {
        var head = "HTTP/1.1 \(resp.status) \(Self.reasonPhrase(resp.status))\r\n"
        for (k, v) in resp.headers { head += "\(k): \(v)\r\n" }
        head += "Connection: close\r\n\r\n"
        var bytes = Data(head.utf8)
        bytes.append(resp.body)
        let dd = bytes.withUnsafeBytes { raw in
            DispatchData(bytes: raw)
        }
        io.write(offset: 0, data: dd, queue: queue) { _, _, _ in
            io.close(flags: .stop)
        }
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        default: return "Error"
        }
    }
}

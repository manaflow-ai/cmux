public import CmuxCore
public import CmuxRemoteDaemon
internal import CmuxSettings
internal import Darwin
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
                    strings: strings,
                    cliRequestHandler: Self.makeCLIRequestHandler(configuration: configuration)
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

    private static func makeCLIRequestHandler(configuration: WorkspaceRemoteConfiguration) -> (@Sendable (Data) throws -> Data)? {
        guard let localSocketPath = configuration.localSocketPath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !localSocketPath.isEmpty else {
            return nil
        }
        return { request in
            switch validateCloudCLIRequest(request, ownerWorkspaceID: configuration.ownerWorkspaceID) {
            case .forward(let forwardedRequest):
                return try roundTripUnixSocket(socketPath: localSocketPath, request: forwardedRequest)
            case .reject(let response):
                return response
            }
        }
    }

    internal enum CloudCLIRequestValidation: Equatable {
        case forward(Data)
        case reject(Data)
    }

    /// Validates VM-originated CLI bridge requests before they hit the local
    /// app socket. The websocket lease authenticates the daemon; this method
    /// keeps VM processes from becoming arbitrary local cmux socket clients.
    internal static func validateCloudCLIRequest(_ request: Data, ownerWorkspaceID: UUID?) -> CloudCLIRequestValidation {
        let requestLimitBytes = 64 * 1024
        guard request.count <= requestLimitBytes else {
            return .reject(cloudCLIErrorResponse(
                id: nil,
                code: "remote_cli_request_too_large",
                message: "Cloud CLI request is too large"
            ))
        }
        guard let object = try? JSONSerialization.jsonObject(with: request, options: []),
              let envelope = object as? [String: Any] else {
            return .reject(cloudCLIErrorResponse(
                id: nil,
                code: "parse_error",
                message: "Invalid JSON"
            ))
        }

        let requestID = envelope["id"]
        guard let ownerWorkspaceID else {
            return .reject(cloudCLIErrorResponse(
                id: requestID,
                code: "remote_cli_unscoped",
                message: "Cloud CLI bridge is not scoped to a workspace"
            ))
        }
        guard let method = (envelope["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !method.isEmpty else {
            return .reject(cloudCLIErrorResponse(
                id: requestID,
                code: "invalid_request",
                message: "Missing method"
            ))
        }
        guard let params = envelope["params"] as? [String: Any] else {
            return .reject(cloudCLIErrorResponse(
                id: requestID,
                code: "invalid_params",
                message: "Cloud CLI request params must be an object"
            ))
        }

        switch method {
        case "notification.create_for_caller":
            return validateCloudCLINotification(
                requestID: requestID,
                params: params,
                ownerWorkspaceID: ownerWorkspaceID,
                workspaceKey: "preferred_workspace_id",
                surfaceKey: "preferred_surface_id",
                requireWorkspace: true,
                requireSurface: true
            )
        case "notification.create_for_target":
            return validateCloudCLINotification(
                requestID: requestID,
                params: params,
                ownerWorkspaceID: ownerWorkspaceID,
                workspaceKey: "workspace_id",
                surfaceKey: "surface_id",
                requireWorkspace: true,
                requireSurface: true
            )
        case "notification.create":
            return validateCloudCLINotification(
                requestID: requestID,
                params: params,
                ownerWorkspaceID: ownerWorkspaceID,
                workspaceKey: "workspace_id",
                surfaceKey: "surface_id",
                requireWorkspace: true,
                requireSurface: true
            )
        default:
            return .reject(cloudCLIErrorResponse(
                id: requestID,
                code: "remote_cli_method_denied",
                message: "Cloud CLI bridge only supports scoped notifications from the VM"
            ))
        }
    }

    private static func validateCloudCLINotification(
        requestID: Any?,
        params: [String: Any],
        ownerWorkspaceID: UUID,
        workspaceKey: String,
        surfaceKey: String,
        requireWorkspace: Bool,
        requireSurface: Bool
    ) -> CloudCLIRequestValidation {
        let requestedWorkspaceID: UUID
        if let workspaceRaw = (params[workspaceKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspaceRaw.isEmpty {
            guard let parsedWorkspaceID = UUID(uuidString: workspaceRaw) else {
                return .reject(cloudCLIErrorResponse(
                    id: requestID,
                    code: "invalid_params",
                    message: "Cloud CLI notification requires a valid workspace_id"
                ))
            }
            requestedWorkspaceID = parsedWorkspaceID
        } else if requireWorkspace {
            return .reject(cloudCLIErrorResponse(
                id: requestID,
                code: "invalid_params",
                message: "Cloud CLI notification requires a valid workspace_id"
            ))
        } else {
            requestedWorkspaceID = ownerWorkspaceID
        }
        guard requestedWorkspaceID == ownerWorkspaceID else {
            return .reject(cloudCLIErrorResponse(
                id: requestID,
                code: "remote_cli_workspace_denied",
                message: "Cloud CLI notification target does not match this workspace"
            ))
        }
        let surfaceRaw: String?
        if let raw = (params[surfaceKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            guard UUID(uuidString: raw) != nil else {
                return .reject(cloudCLIErrorResponse(
                    id: requestID,
                    code: "invalid_params",
                    message: "Cloud CLI notification requires a valid surface_id"
                ))
            }
            surfaceRaw = raw
        } else if requireSurface {
            return .reject(cloudCLIErrorResponse(
                id: requestID,
                code: "invalid_params",
                message: "Cloud CLI notification requires a valid surface_id"
            ))
        } else {
            surfaceRaw = nil
        }

        var forwardedParams: [String: Any] = [
            "workspace_id": requestedWorkspaceID.uuidString,
        ]
        if let surfaceRaw {
            forwardedParams["surface_id"] = surfaceRaw
        }
        for key in ["title", "subtitle", "body"] {
            if let value = params[key] as? String {
                forwardedParams[key] = value
            }
        }
        let forwarded: [String: Any] = [
            "id": requestID ?? NSNull(),
            "method": surfaceRaw == nil ? "notification.create" : "notification.create_for_target",
            "params": forwardedParams,
        ]
        guard JSONSerialization.isValidJSONObject(forwarded),
              let data = try? JSONSerialization.data(withJSONObject: forwarded, options: []) else {
            return .reject(cloudCLIErrorResponse(
                id: requestID,
                code: "encode_error",
                message: "Failed to encode Cloud CLI request"
            ))
        }
        return .forward(data + Data([0x0A]))
    }

    private static func cloudCLIErrorResponse(id: Any?, code: String, message: String) -> Data {
        let response: [String: Any] = [
            "id": id ?? NSNull(),
            "ok": false,
            "error": [
                "code": code,
                "message": message,
            ],
        ]
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response, options: []) else {
            return Data("{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}\n".utf8)
        }
        return data + Data([0x0A])
    }

    internal static func cloudCLIAuthLoginRequest(password: String) throws -> Data {
        let request: [String: Any] = [
            "id": "cloud-cli-auth",
            "method": "auth.login",
            "params": [
                "password": password,
            ],
        ]
        guard JSONSerialization.isValidJSONObject(request) else {
            throw NSError(domain: "cmux.remote.cli-bridge", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "failed to encode local cmux socket auth request",
            ])
        }
        return try JSONSerialization.data(withJSONObject: request, options: []) + Data([0x0A])
    }

    internal static func cloudCLIAuthResponseSucceeded(_ response: Data) -> Bool {
        let trimmed = Data(response.split(separator: 0x0A).first ?? response[...])
        guard let object = try? JSONSerialization.jsonObject(with: trimmed, options: []),
              let envelope = object as? [String: Any] else {
            return false
        }
        return envelope["ok"] as? Bool == true
    }

    private static func roundTripUnixSocket(socketPath: String, request: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "cmux.remote.cli-bridge", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "failed to create local cmux socket",
            ])
        }
        defer { Darwin.close(fd) }

        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: "cmux.remote.cli-bridge", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "local cmux socket path is too long",
            ])
        }
        let sunPathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { rawBuffer in
            let destination = rawBuffer.baseAddress!.advanced(by: sunPathOffset)
            pathBytes.withUnsafeBytes { pathBuffer in
                destination.copyMemory(from: pathBuffer.baseAddress!, byteCount: pathBytes.count)
            }
        }

        let addressLength = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count)
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, addressLength)
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: "cmux.remote.cli-bridge", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "failed to connect to local cmux socket",
            ])
        }

        if let socketPassword = SocketControlPasswordStore().configuredPassword(allowLazyKeychainFallback: true),
           !socketPassword.isEmpty {
            try writeAll(cloudCLIAuthLoginRequest(password: socketPassword), to: fd)
            let authResponse = try readLineFromUnixSocket(fd: fd)
            guard cloudCLIAuthResponseSucceeded(authResponse) else {
                throw NSError(domain: "cmux.remote.cli-bridge", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "local cmux socket auth rejected cloud CLI bridge",
                ])
            }
        }

        try writeAll(request, to: fd)
        _ = shutdown(fd, SHUT_WR)

        return try readRemainingFromUnixSocket(fd: fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var pointer = baseAddress
            while bytesRemaining > 0 {
                let written = Darwin.write(fd, pointer, bytesRemaining)
                if written <= 0 {
                    throw NSError(domain: "cmux.remote.cli-bridge", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "failed to write cloud CLI request",
                    ])
                }
                bytesRemaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    private static func readLineFromUnixSocket(fd: Int32) throws -> Data {
        var response = Data()
        var scratch = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(fd, &scratch, scratch.count)
            if count > 0 {
                response.append(scratch, count: count)
                if scratch.prefix(count).contains(0x0A) {
                    return response
                }
                continue
            }
            if count == 0 {
                return response
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if !response.isEmpty {
                    return response
                }
                throw NSError(domain: "cmux.remote.cli-bridge", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "timed out waiting for local cmux response",
                ])
            }
            throw NSError(domain: "cmux.remote.cli-bridge", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "failed to read local cmux response",
            ])
        }
    }

    private static func readRemainingFromUnixSocket(fd: Int32) throws -> Data {
        var response = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &scratch, scratch.count)
            if count > 0 {
                response.append(scratch, count: count)
                continue
            }
            if count == 0 {
                break
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                if !response.isEmpty {
                    break
                }
                throw NSError(domain: "cmux.remote.cli-bridge", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "timed out waiting for local cmux response",
                ])
            }
            throw NSError(domain: "cmux.remote.cli-bridge", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "failed to read local cmux response",
            ])
        }
        return response
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

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


final class WorkspaceRemoteDaemonProxyTunnel {
    private final class ProxySession {
        private static let maxHandshakeBytes = 64 * 1024
        private static let remoteLoopbackProxyAliasHost = RemoteLoopbackProxyAlias.aliasHost

        private enum HandshakeProtocol {
            case undecided
            case socks5
            case connect
        }

        private enum SocksStage {
            case greeting
            case request
        }

        private struct SocksRequest {
            let host: String
            let port: Int
            let command: UInt8
            let consumedBytes: Int
        }

        let id = UUID()

        private let connection: NWConnection
        private let rpcClient: WorkspaceRemoteDaemonRPCClient
        private let queue: DispatchQueue
        private let onClose: (UUID) -> Void

        private var isClosed = false
        private var protocolKind: HandshakeProtocol = .undecided
        private var socksStage: SocksStage = .greeting
        private var handshakeBuffer = Data()
        private var streamID: String?
        private var localInputEOF = false
        private var rewritesLoopbackHTTPHeaders = false
        private var loopbackRequestHeaderRewriter: RemoteLoopbackHTTPRequestStreamRewriter?
        private var pendingRemoteHTTPHeaderBytes = Data()
        private var hasForwardedRemoteHTTPHeaders = false

        init(
            connection: NWConnection,
            rpcClient: WorkspaceRemoteDaemonRPCClient,
            queue: DispatchQueue,
            onClose: @escaping (UUID) -> Void
        ) {
            self.connection = connection
            self.rpcClient = rpcClient
            self.queue = queue
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    self.close(reason: "proxy client connection failed: \(error)")
                case .cancelled:
                    self.close(reason: nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receiveNext()
        }

        func stop() {
            close(reason: nil)
        }

        private func receiveNext() {
            guard !isClosed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, error in
                guard let self, !self.isClosed else { return }

                if let data, !data.isEmpty {
                    if self.streamID == nil {
                        if self.handshakeBuffer.count + data.count > Self.maxHandshakeBytes {
                            self.close(reason: "proxy handshake exceeded \(Self.maxHandshakeBytes) bytes")
                            return
                        }
                        self.handshakeBuffer.append(data)
                        self.processHandshakeBuffer()
                    } else {
                        self.forwardToRemote(data, eof: isComplete)
                    }
                }

                if isComplete {
                    // Treat local EOF as a half-close: keep remote read loop alive so we can
                    // drain upstream response bytes (for example curl closing write-side after
                    // sending an HTTP request through SOCKS/CONNECT).
                    self.localInputEOF = true
                    if self.streamID != nil, data?.isEmpty ?? true {
                        self.forwardToRemote(Data(), eof: true, allowAfterEOF: true)
                    }
                    if self.streamID == nil {
                        self.close(reason: nil)
                    }
                    return
                }
                if let error {
                    self.close(reason: "proxy client receive error: \(error)")
                    return
                }

                self.receiveNext()
            }
        }

        private func processHandshakeBuffer() {
            guard !isClosed else { return }
            while streamID == nil {
                switch protocolKind {
                case .undecided:
                    guard let first = handshakeBuffer.first else { return }
                    protocolKind = (first == 0x05) ? .socks5 : .connect
                case .socks5:
                    if !processSocksHandshakeStep() {
                        return
                    }
                case .connect:
                    if !processConnectHandshakeStep() {
                        return
                    }
                }
            }
        }

        private func processSocksHandshakeStep() -> Bool {
            switch socksStage {
            case .greeting:
                guard handshakeBuffer.count >= 2 else { return false }
                let methodCount = Int(handshakeBuffer[1])
                let total = 2 + methodCount
                guard handshakeBuffer.count >= total else { return false }

                let methods = [UInt8](handshakeBuffer[2..<total])
                handshakeBuffer = Data(handshakeBuffer.dropFirst(total))
                socksStage = .request

                if !methods.contains(0x00) {
                    sendAndClose(Data([0x05, 0xFF]))
                    return false
                }
                sendLocal(Data([0x05, 0x00]))
                return true

            case .request:
                let request: SocksRequest
                do {
                    guard let parsed = try parseSocksRequest(from: handshakeBuffer) else { return false }
                    request = parsed
                } catch {
                    sendAndClose(Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    return false
                }

                let pending = handshakeBuffer.count > request.consumedBytes
                    ? Data(handshakeBuffer[request.consumedBytes...])
                    : Data()
                handshakeBuffer = Data()
                guard request.command == 0x01 else {
                    sendAndClose(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
                    return false
                }

                openRemoteStream(
                    host: request.host,
                    port: request.port,
                    successResponse: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                    failureResponse: Data([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                    pendingPayload: pending
                )
                return false
            }
        }

        private func parseSocksRequest(from data: Data) throws -> SocksRequest? {
            let bytes = [UInt8](data)
            guard bytes.count >= 4 else { return nil }
            guard bytes[0] == 0x05 else {
                throw NSError(domain: "cmux.remote.proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS version"])
            }

            let command = bytes[1]
            let addressType = bytes[3]
            var cursor = 4
            let host: String

            switch addressType {
            case 0x01:
                guard bytes.count >= cursor + 4 + 2 else { return nil }
                let octets = bytes[cursor..<(cursor + 4)].map { String($0) }
                host = octets.joined(separator: ".")
                cursor += 4

            case 0x03:
                guard bytes.count >= cursor + 1 else { return nil }
                let length = Int(bytes[cursor])
                cursor += 1
                guard bytes.count >= cursor + length + 2 else { return nil }
                let hostData = Data(bytes[cursor..<(cursor + length)])
                host = String(data: hostData, encoding: .utf8) ?? ""
                cursor += length

            case 0x04:
                guard bytes.count >= cursor + 16 + 2 else { return nil }
                var address = in6_addr()
                withUnsafeMutableBytes(of: &address) { target in
                    for i in 0..<16 {
                        target[i] = bytes[cursor + i]
                    }
                }
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let pointer = withUnsafePointer(to: &address) {
                    inet_ntop(AF_INET6, UnsafeRawPointer($0), &text, socklen_t(INET6_ADDRSTRLEN))
                }
                host = pointer != nil ? String(cString: text) : ""
                cursor += 16

            default:
                throw NSError(domain: "cmux.remote.proxy", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS address type"])
            }

            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "cmux.remote.proxy", code: 3, userInfo: [NSLocalizedDescriptionKey: "empty SOCKS host"])
            }
            guard bytes.count >= cursor + 2 else { return nil }
            let port = Int(UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))
            cursor += 2

            guard port > 0 && port <= 65535 else {
                throw NSError(domain: "cmux.remote.proxy", code: 4, userInfo: [NSLocalizedDescriptionKey: "invalid SOCKS port"])
            }

            return SocksRequest(host: host, port: port, command: command, consumedBytes: cursor)
        }

        private func processConnectHandshakeStep() -> Bool {
            let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard let headerRange = handshakeBuffer.range(of: marker) else { return false }

            let headerData = Data(handshakeBuffer[..<headerRange.upperBound])
            let pending = headerRange.upperBound < handshakeBuffer.count
                ? Data(handshakeBuffer[headerRange.upperBound...])
                : Data()
            handshakeBuffer = Data()
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            let firstLine = headerText.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, parts[0].uppercased() == "CONNECT" else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            guard let (host, port) = Self.parseConnectAuthority(parts[1]) else {
                sendAndClose(Self.httpResponse(status: "400 Bad Request"))
                return false
            }

            openRemoteStream(
                host: host,
                port: port,
                successResponse: Self.httpResponse(status: "200 Connection Established", closeAfterResponse: false),
                failureResponse: Self.httpResponse(status: "502 Bad Gateway", closeAfterResponse: true),
                pendingPayload: pending
            )
            return false
        }

        private func openRemoteStream(
            host: String,
            port: Int,
            successResponse: Data,
            failureResponse: Data,
            pendingPayload: Data
        ) {
            guard !isClosed else { return }
            do {
                rewritesLoopbackHTTPHeaders =
                    RemoteLoopbackProxyAlias.localhostFamilyHost(
                        forAliasHost: host,
                        aliasHost: Self.remoteLoopbackProxyAliasHost
                    ) != nil
                loopbackRequestHeaderRewriter = rewritesLoopbackHTTPHeaders
                    ? RemoteLoopbackHTTPRequestStreamRewriter(aliasHost: Self.remoteLoopbackProxyAliasHost)
                    : nil
                pendingRemoteHTTPHeaderBytes = Data()
                hasForwardedRemoteHTTPHeaders = false
                let targetHost = Self.normalizedProxyTargetHost(host)
                let streamID = try rpcClient.openStream(host: targetHost, port: port)
                self.streamID = streamID
                try rpcClient.attachStream(streamID: streamID, queue: queue) { [weak self] event in
                    self?.handleRemoteStreamEvent(streamID: streamID, event: event)
                }
                connection.send(content: successResponse, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close(reason: "proxy client send error: \(error)")
                        return
                    }
                    if !pendingPayload.isEmpty {
                        self.forwardToRemote(pendingPayload, allowAfterEOF: true)
                    }
                })
            } catch {
                sendAndClose(failureResponse)
            }
        }

        private func forwardToRemote(_ data: Data, eof: Bool = false, allowAfterEOF: Bool = false) {
            guard !isClosed else { return }
            guard !localInputEOF || allowAfterEOF else { return }
            guard let streamID else { return }
            do {
                let outgoingData: Data
                if rewritesLoopbackHTTPHeaders {
                    outgoingData = loopbackRequestHeaderRewriter?.rewriteNextChunk(data, eof: eof) ?? data
                } else {
                    outgoingData = data
                }
                guard !outgoingData.isEmpty else { return }
                try rpcClient.writeStream(streamID: streamID, data: outgoingData)
            } catch {
                close(reason: "proxy.write failed: \(error.localizedDescription)")
            }
        }

        private func handleRemoteStreamEvent(
            streamID: String,
            event: WorkspaceRemoteDaemonRPCClient.StreamEvent
        ) {
            guard !isClosed else { return }
            guard self.streamID == streamID else { return }

            switch event {
            case .data(let data):
                forwardRemotePayloadToLocal(data, eof: false)

            case .eof(let data):
                forwardRemotePayloadToLocal(data, eof: true)

            case .error(let detail):
                close(reason: "proxy.stream failed: \(detail)")
            }
        }

        private func forwardRemotePayloadToLocal(_ data: Data, eof: Bool) {
            let localData = rewriteRemoteResponseIfNeeded(data, eof: eof)
            if !localData.isEmpty {
                connection.send(content: localData, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.close(reason: "proxy client send error: \(error)")
                        return
                    }
                    if eof {
                        self.close(reason: nil)
                    }
                })
                return
            }

            if eof {
                close(reason: nil)
            }
        }

        private func rewriteRemoteResponseIfNeeded(_ data: Data, eof: Bool) -> Data {
            guard rewritesLoopbackHTTPHeaders else { return data }
            guard !data.isEmpty else { return data }
            guard !hasForwardedRemoteHTTPHeaders else { return data }

            pendingRemoteHTTPHeaderBytes.append(data)
            let marker = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard pendingRemoteHTTPHeaderBytes.range(of: marker) != nil else {
                guard eof else { return Data() }
                hasForwardedRemoteHTTPHeaders = true
                let payload = pendingRemoteHTTPHeaderBytes
                pendingRemoteHTTPHeaderBytes = Data()
                return payload
            }

            hasForwardedRemoteHTTPHeaders = true
            let payload = pendingRemoteHTTPHeaderBytes
            pendingRemoteHTTPHeaderBytes = Data()
            return RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
                data: payload,
                aliasHost: Self.remoteLoopbackProxyAliasHost
            )
        }

        private func close(reason: String?) {
            guard !isClosed else { return }
            isClosed = true

            let streamID = self.streamID
            self.streamID = nil

            if let streamID {
                rpcClient.closeStream(streamID: streamID)
            }
            connection.cancel()
            onClose(id)
        }

        private func sendLocal(_ data: Data) {
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.close(reason: "proxy client send error: \(error)")
                }
            })
        }

        private func sendAndClose(_ data: Data) {
            guard !isClosed else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.close(reason: nil)
            })
        }

        private static func parseConnectAuthority(_ authority: String) -> (host: String, port: Int)? {
            let trimmed = authority.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if trimmed.hasPrefix("[") {
                guard let closing = trimmed.firstIndex(of: "]") else { return nil }
                let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
                let portStart = trimmed.index(after: closing)
                guard portStart < trimmed.endIndex, trimmed[portStart] == ":" else { return nil }
                let portString = String(trimmed[trimmed.index(after: portStart)...])
                guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
                return (host, port)
            }

            guard let colon = trimmed.lastIndex(of: ":") else { return nil }
            let host = String(trimmed[..<colon])
            let portString = String(trimmed[trimmed.index(after: colon)...])
            guard !host.isEmpty else { return nil }
            guard let port = Int(portString), port > 0, port <= 65535 else { return nil }
            return (host, port)
        }

        private static func normalizedProxyTargetHost(_ host: String) -> String {
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            // BrowserPanel rewrites loopback URLs to this alias so proxy routing works.
            // Resolve it back to true loopback before dialing from the remote daemon.
            if RemoteLoopbackProxyAlias.localhostFamilyHost(
                forAliasHost: normalized,
                aliasHost: remoteLoopbackProxyAliasHost
            ) != nil {
                return "127.0.0.1"
            }
            return host
        }

        private static func httpResponse(status: String, closeAfterResponse: Bool = true) -> Data {
            var text = "HTTP/1.1 \(status)\r\nProxy-Agent: cmux\r\n"
            if closeAfterResponse {
                text += "Connection: close\r\n"
            }
            text += "\r\n"
            return Data(text.utf8)
        }
    }

    private let configuration: WorkspaceRemoteConfiguration
    private let remotePath: String
    private let localPort: Int
    private let onFatalError: (String) -> Void
    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.daemon-tunnel.\(UUID().uuidString)", qos: .utility)

    private var listener: NWListener?
    private var rpcClient: WorkspaceRemoteDaemonRPCClient?
    private var sessions: [UUID: ProxySession] = [:]
    private var ptyBridgeServers: [UUID: WorkspaceRemotePTYBridgeServer] = [:]
    private var isStopped = false

    init(
        configuration: WorkspaceRemoteConfiguration,
        remotePath: String,
        localPort: Int,
        onFatalError: @escaping (String) -> Void
    ) {
        self.configuration = configuration
        self.remotePath = remotePath
        self.localPort = localPort
        self.onFatalError = onFatalError
    }

    func start() throws {
        var capturedError: Error?
        queue.sync {
            guard !isStopped else {
                capturedError = NSError(domain: "cmux.remote.proxy", code: 20, userInfo: [
                    NSLocalizedDescriptionKey: "proxy tunnel already stopped",
                ])
                return
            }
            do {
                let client = WorkspaceRemoteDaemonRPCClient(
                    configuration: configuration,
                    remotePath: remotePath
                ) { [weak self] detail in
                    self?.queue.async {
                        self?.failLocked("Remote daemon transport failed: \(detail)")
                    }
                }
                try client.start()

                let listener = try Self.makeLoopbackListener(port: localPort)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.queue.async {
                        self?.acceptConnectionLocked(connection)
                    }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    self?.queue.async {
                        self?.handleListenerStateLocked(state)
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

    func stop() {
        queue.sync {
            stopLocked(notify: false)
        }
    }

    func listPTY() throws -> [[String: Any]] {
        try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.pty", code: 30, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            return try rpcClient.listPTY()
        }
    }

    func closePTY(sessionID: String) throws {
        try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.pty", code: 31, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            try rpcClient.closePTY(sessionID: sessionID)
        }
    }

    func resizePTY(sessionID: String, attachmentID: String, attachmentToken: String, cols: Int, rows: Int) throws {
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

    func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) throws {
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

    func startPTYBridge(sessionID: String, attachmentID: String, command: String?, requireExisting: Bool) throws -> WorkspaceRemotePTYBridgeServer.Endpoint {
        try queue.sync {
            guard let rpcClient, !isStopped else {
                throw NSError(domain: "cmux.remote.pty", code: 33, userInfo: [
                    NSLocalizedDescriptionKey: "remote daemon tunnel is not ready",
                ])
            }
            let bridgeID = UUID()
            let server = WorkspaceRemotePTYBridgeServer(
                rpcClient: rpcClient,
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting
            ) { [weak self] in
                self?.queue.async {
                    self?.ptyBridgeServers.removeValue(forKey: bridgeID)
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

        let session = ProxySession(
            connection: connection,
            rpcClient: rpcClient,
            queue: queue
        ) { [weak self] id in
            self?.queue.async {
                self?.sessions.removeValue(forKey: id)
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


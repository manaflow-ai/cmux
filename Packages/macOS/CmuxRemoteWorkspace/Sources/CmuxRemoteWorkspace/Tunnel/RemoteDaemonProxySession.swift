import CmuxCore
import CmuxRemoteDaemon
import Darwin
public import Foundation
public import Network

/// The cross-module handle for one accepted, authenticated browser-proxy
/// connection. It lets the ssh-tmux transport reuse the same credentialed
/// SOCKS5/HTTP-CONNECT parser as the daemon-backed tunnel.
public protocol RemoteDaemonProxySessionHandling: AnyObject, Sendable {
    var id: UUID { get }
    func start()
    func stop()
}

/// Creates credentialed browser-proxy sessions for one local connection.
public struct RemoteDaemonProxySessionFactory: Sendable {
    public init() {}

    public func makeSession(
        connection: NWConnection,
        credential: BrowserProxyCredential,
        rpcClient: any RemoteProxyStreamOpening,
        queue: DispatchQueue,
        onClose: @escaping (UUID) -> Void
    ) -> any RemoteDaemonProxySessionHandling {
        RemoteDaemonProxySession(
            connection: connection,
            credential: credential,
            rpcClient: rpcClient,
            queue: queue,
            onClose: onClose
        )
    }
}

/// One accepted local proxy connection inside ``RemoteDaemonProxyTunnel``:
/// parses the SOCKS5 or HTTP CONNECT handshake, opens a matching daemon
/// stream, then shuttles bytes both ways (rewriting loopback-alias HTTP
/// headers when the target is the alias host).
///
/// The listener is reachable by every local account, so both handshakes must
/// present the tunnel's ``BrowserProxyCredential`` before any daemon stream
/// opens: SOCKS5 through username/password authentication (RFC 1929), HTTP
/// CONNECT through `Proxy-Authorization: Basic`.
///
/// Isolation design (faithful lift of the legacy nested `ProxySession`): all
/// mutable state is confined to the tunnel's serial `queue`. Mutators are the
/// `NWConnection` receive/state callbacks (started on `queue`), the RPC
/// client's stream events (attached with `queue`), and `stop()` from the
/// tunnel (already on `queue`). Nothing reads off-queue, so a serial queue
/// rather than an actor preserves the legacy synchronous ordering of
/// handshake parsing and close side effects. `@unchecked Sendable` because
/// the `@Sendable` Network callbacks capture `self`; the queue confinement
/// above is the safety argument.
final class RemoteDaemonProxySession: RemoteDaemonProxySessionHandling, @unchecked Sendable {
    private static let maxHandshakeBytes = 64 * 1024
    private static let remoteLoopbackProxyAliasHost = RemoteLoopbackProxyAlias.aliasHost

    private enum HandshakeProtocol {
        case undecided
        case socks5
        case connect
    }

    private enum SocksStage {
        case greeting
        case authentication
        case request
    }

    private struct SocksRequest {
        let host: String
        let port: Int
        let command: UInt8
        let consumedBytes: Int
    }

    public let id = UUID()

    private let connection: NWConnection
    private let credential: BrowserProxyCredential
    private let rpcClient: any RemoteProxyStreamOpening
    private let queue: DispatchQueue
    private let onClose: (UUID) -> Void

    private var isClosed = false
    /// Set once a final response is queued; later handshake bytes are ignored
    /// so a refused client cannot retry on the same connection.
    private var isClosingAfterResponse = false
    private var protocolKind: HandshakeProtocol = .undecided
    private var socksStage: SocksStage = .greeting
    private var handshakeBuffer = Data()
    private var streamID: String?
    private var localInputEOF = false
    private var rewritesLoopbackHTTPHeaders = false
    private var loopbackRequestHeaderRewriter: RemoteLoopbackHTTPRequestStreamRewriter?
    private var pendingRemoteHTTPHeaderBytes = Data()
    private var hasForwardedRemoteHTTPHeaders = false

    public init(
        connection: NWConnection,
        credential: BrowserProxyCredential,
        rpcClient: any RemoteProxyStreamOpening,
        queue: DispatchQueue,
        onClose: @escaping (UUID) -> Void
    ) {
        self.connection = connection
        self.credential = credential
        self.rpcClient = rpcClient
        self.queue = queue
        self.onClose = onClose
    }

    public func start() {
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

    public func stop() {
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
        guard !isClosed, !isClosingAfterResponse else { return }
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

            // Only username/password (0x02) is acceptable; "no authentication"
            // (0x00) is refused even when it is the only method offered.
            guard methods.contains(0x02) else {
                sendAndClose(Data([0x05, 0xFF]))
                return false
            }
            socksStage = .authentication
            sendLocal(Data([0x05, 0x02]))
            return true

        case .authentication:
            let bytes = [UInt8](handshakeBuffer)
            guard bytes.count >= 2 else { return false }
            let usernameLength = Int(bytes[1])
            guard bytes.count >= 3 + usernameLength else { return false }
            let passwordLength = Int(bytes[2 + usernameLength])
            let total = 3 + usernameLength + passwordLength
            guard bytes.count >= total else { return false }

            let username = Array(bytes[2..<(2 + usernameLength)])
            let password = Array(bytes[(3 + usernameLength)..<total])
            guard bytes[0] == 0x01, credential.matches(username: username, password: password) else {
                sendAndClose(Data([0x01, 0x01]))
                return false
            }
            handshakeBuffer = Data(handshakeBuffer.dropFirst(total))
            socksStage = .request
            sendLocal(Data([0x01, 0x00]))
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
            host = pointer != nil
                ? String(decoding: text.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                : ""
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

        let headerLines = headerText.components(separatedBy: "\r\n")
        guard hasValidProxyAuthorization(headerLines: headerLines.dropFirst()) else {
            sendAndClose(Self.httpResponse(
                status: "407 Proxy Authentication Required",
                extraHeaders: ["Proxy-Authenticate: Basic realm=\"cmux\"", "Content-Length: 0"]
            ))
            return false
        }

        let firstLine = headerLines.first ?? ""
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

    /// Returns whether the first `Proxy-Authorization` header carries this
    /// tunnel's credential as HTTP Basic.
    private func hasValidProxyAuthorization(headerLines: ArraySlice<String>) -> Bool {
        let prefix = "proxy-authorization:"
        guard let line = headerLines.first(where: { $0.lowercased().hasPrefix(prefix) }) else {
            return false
        }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].lowercased() == "basic",
              let decoded = Data(base64Encoded: parts[1].trimmingCharacters(in: .whitespaces)) else {
            return false
        }
        let bytes = [UInt8](decoded)
        guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")) else { return false }
        return credential.matches(
            username: Array(bytes[..<colon]),
            password: Array(bytes[(colon + 1)...])
        )
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
            let streamID = try rpcClient.openStream(host: targetHost, port: port, timeoutMs: 10_000)
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
        event: RemoteDaemonStreamEvent
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
        isClosingAfterResponse = true
        handshakeBuffer = Data()
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

    private static func httpResponse(
        status: String,
        closeAfterResponse: Bool = true,
        extraHeaders: [String] = []
    ) -> Data {
        var text = "HTTP/1.1 \(status)\r\nProxy-Agent: cmux\r\n"
        for header in extraHeaders {
            text += "\(header)\r\n"
        }
        if closeAfterResponse {
            text += "Connection: close\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }
}

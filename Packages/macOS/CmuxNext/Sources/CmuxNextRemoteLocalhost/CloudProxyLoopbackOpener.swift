import CryptoKit
import Foundation
import Network

/// Opens a machine loopback tunnel through an authenticated local HTTP proxy.
///
/// `cmux-cloud` returns one random credential with each browser route.
/// Chromium never receives that credential: the app's peer-checked proxy calls
/// this opener, which mutually authenticates a `CONNECT` request with HMAC.
public struct CloudProxyLoopbackOpener: LoopbackTunnelOpening {
    private static let maxResponseHeadBytes = 16 * 1024
    private let proxyPort: UInt16
    private let credential: ProxyCredential
    private let handshakeTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    // concurrency-allow: Network.framework requires an event-delivery queue; it protects no mutable Swift state.
    private let queue: DispatchQueue

    /// Creates an opener for one authenticated `cmux-cloud` browser route.
    ///
    /// - Parameters:
    ///   - proxyPort: The local proxy port returned by `cloud.browser.open`.
    ///   - credential: The per-route HMAC credential returned by `cloud.browser.open`.
    ///   - handshakeTimeout: The maximum time to wait for the proxy's CONNECT response.
    public init(
        proxyPort: UInt16,
        credential: ProxyCredential,
        handshakeTimeout: Duration = .seconds(10)
    ) {
        self.init(
            proxyPort: proxyPort,
            credential: credential,
            handshakeTimeout: handshakeTimeout,
            sleep: { duration in
                // wakeup-allow: one bounded, cancellable network-handshake deadline; tests inject this clock.
                try await ContinuousClock().sleep(for: duration)
            }
        )
    }

    /// Test seam for advancing the one-shot handshake deadline without wall-clock delay.
    init(
        proxyPort: UInt16,
        credential: ProxyCredential,
        handshakeTimeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.proxyPort = proxyPort
        self.credential = credential
        self.handshakeTimeout = handshakeTimeout
        self.sleep = sleep
        queue = DispatchQueue(label: "com.cmuxterm.next.cloud-browser-proxy", qos: .userInitiated)
    }

    public func openTunnel(host: String, port: UInt16) async throws(LoopbackTunnelFailure) -> any LoopbackTunnel {
        guard let endpointPort = NWEndpoint.Port(rawValue: proxyPort) else {
            throw .unavailable("Cloud browser proxy unavailable")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        tcp.noDelay = true
        let connection = NWConnection(host: .ipv4(.loopback), port: endpointPort, using: NWParameters(tls: nil, tcp: tcp))
        do {
            return try await withTaskCancellationHandler {
                guard await connection.ready(on: queue) else {
                    throw LoopbackTunnelFailure.unavailable("Cloud browser proxy unavailable")
                }
                let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]:\(port)" : "\(host):\(port)"
                let nonce = ProxyCredential.randomToken(bytes: 32)
                let clientProof = Self.authenticationCode(
                    secret: credential.password,
                    message: "cmux-client-v1\n\(nonce)\n\(authority)"
                )
                let request = Data((
                    "CONNECT \(authority) HTTP/1.1\r\n"
                        + "Host: \(authority)\r\n"
                        + "Proxy-Authorization: CMUX \(credential.username):\(nonce):\(clientProof)\r\n"
                        + "Connection: close\r\n\r\n"
                ).utf8)
                try await connection.sendAll(request)
                let (head, rest) = try await handshakeResponse(from: connection)
                // 407: the route's credential is not the proxy's (a newer cmux-cloud, a new link):
                // the route is gone, so its owner may ask for it again (CloudBrowserRoute).
                if Self.status(head) == 407 {
                    connection.cancel()
                    throw LoopbackTunnelFailure.unavailable("Cloud browser route expired")
                }
                guard Self.isEstablished(head), Self.hasValidServerProof(
                    head,
                    secret: credential.password,
                    message: "cmux-server-v1\n\(nonce)\n\(authority)"
                ) else {
                    connection.cancel()
                    throw LoopbackTunnelFailure.other("Cloud browser proxy refused the tunnel")
                }
                return CloudProxyLoopbackTunnel(connection: connection, initialData: rest)
            } onCancel: {
                connection.cancel()
            }
        } catch let failure as LoopbackTunnelFailure {
            connection.cancel()
            throw failure
        } catch {
            connection.cancel()
            throw .other("Cloud browser proxy connection failed")
        }
    }

    private func handshakeResponse(from connection: NWConnection) async throws(LoopbackTunnelFailure) -> (Data, Data) {
        do {
            // concurrency-allow: the injected sleeper honors cancellation and timeout cancels NWConnection, so both group children exit.
            return try await withThrowingTaskGroup(of: (Data, Data).self) { group in
                group.addTask { try await Self.readResponseHead(from: connection) }
                group.addTask {
                    // wakeup-allow: this is the handshake's one-shot deadline, not polling or settling.
                    try await sleep(handshakeTimeout)
                    connection.cancel()
                    throw LoopbackTunnelFailure.other("Cloud browser proxy handshake timed out")
                }
                defer { group.cancelAll() }
                guard let response = try await group.next() else {
                    throw LoopbackTunnelFailure.other("Cloud browser proxy connection ended")
                }
                return response
            }
        } catch let failure as LoopbackTunnelFailure {
            throw failure
        } catch {
            throw .other("Cloud browser proxy connection failed")
        }
    }

    private static func readResponseHead(from connection: NWConnection) async throws -> (Data, Data) {
        var buffer = Data()
        while buffer.count <= maxResponseHeadBytes {
            let (chunk, complete) = try await connection.receiveChunk(max: 4096)
            if let chunk { buffer.append(chunk) }
            if buffer.count > maxResponseHeadBytes {
                throw LoopbackTunnelFailure.other("Cloud browser proxy returned an oversized response")
            }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8))?.upperBound {
                return (Data(buffer[..<end]), Data(buffer[end...]))
            }
            if complete { break }
        }
        throw LoopbackTunnelFailure.other("Cloud browser proxy returned an invalid response")
    }

    private static func isEstablished(_ head: Data) -> Bool { status(head) == 200 }

    /// The status code of a response head, nil when it is not an HTTP/1 status line.
    static func status(_ head: Data) -> Int? {
        guard let text = String(data: head, encoding: .utf8), let first = text.components(separatedBy: "\r\n").first else {
            return nil
        }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].starts(with: "HTTP/1."), parts[1].count == 3 else { return nil }
        return Int(parts[1])
    }

    private static func authenticationCode(secret: String, message: String) -> String {
        HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        ).map { String(format: "%02x", $0) }.joined()
    }

    private static func hasValidServerProof(_ head: Data, secret: String, message: String) -> Bool {
        guard let text = String(data: head, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").dropFirst().first(where: {
                  $0.split(separator: ":", maxSplits: 1).first?.lowercased() == "proxy-authentication-info"
              }),
              let separator = line.firstIndex(of: ":")
        else { return false }
        let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("CMUX "), let proof = Self.hexBytes(String(value.dropFirst(5))) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: Data(message.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
    }

    private static func hexBytes(_ value: String) -> [UInt8]? {
        guard value.count == 64, value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

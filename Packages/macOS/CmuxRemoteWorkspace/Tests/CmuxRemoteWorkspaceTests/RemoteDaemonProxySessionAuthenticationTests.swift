import CmuxCore
import Foundation
import Network
import Testing
@testable import CmuxRemoteWorkspace

/// Loopback listener that runs one ``RemoteDaemonProxySession`` per accepted
/// connection, the way ``RemoteDaemonProxyTunnel`` does, against a fake
/// daemon. State is confined to `queue`, like the tunnel.
final class ProxySessionTestHarness: @unchecked Sendable {
    let rpcClient: ProxyStreamTestRPCClient
    let credential: BrowserProxyCredential
    private let queue = DispatchQueue(label: "proxy-session-test-harness")
    private let listener: NWListener
    private var sessions: [UUID: RemoteDaemonProxySession] = [:]

    private init(listener: NWListener, credential: BrowserProxyCredential, rpcClient: ProxyStreamTestRPCClient) {
        self.listener = listener
        self.credential = credential
        self.rpcClient = rpcClient
    }

    /// Starts a harness on an ephemeral `127.0.0.1` port.
    static func start(
        credential: BrowserProxyCredential = .random(),
        rpcClient: ProxyStreamTestRPCClient = ProxyStreamTestRPCClient()
    ) throws -> ProxySessionTestHarness {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let harness = ProxySessionTestHarness(
            listener: try NWListener(using: parameters),
            credential: credential,
            rpcClient: rpcClient
        )
        let ready = DispatchSemaphore(value: 0)
        harness.listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        harness.listener.newConnectionHandler = { [weak harness] connection in
            guard let harness else {
                connection.cancel()
                return
            }
            harness.queue.async { harness.acceptLocked(connection) }
        }
        harness.listener.start(queue: harness.queue)
        guard ready.wait(timeout: .now() + 5) == .success, harness.listener.port != nil else {
            harness.stop()
            throw NSError(domain: "test.remote.proxy", code: 1)
        }
        return harness
    }

    var port: Int { Int(listener.port?.rawValue ?? 0) }

    var endpoint: NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
    }

    func makeClient() -> BridgeTestClient {
        BridgeTestClient(host: "127.0.0.1", port: port)
    }

    func stop() {
        listener.cancel()
        queue.sync {
            let sessions = Array(self.sessions.values)
            self.sessions.removeAll()
            sessions.forEach { $0.stop() }
        }
    }

    private func acceptLocked(_ connection: NWConnection) {
        let session = RemoteDaemonProxySession(
            connection: connection,
            credential: credential,
            rpcClient: rpcClient,
            queue: queue,
            onClose: { [weak self] id in
                self?.sessions.removeValue(forKey: id)
            }
        )
        sessions[session.id] = session
        session.start()
    }
}

@Suite("Remote daemon proxy session authentication", .serialized)
struct RemoteDaemonProxySessionAuthenticationTests {
    private static let socksSuccessReply = Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])

    // MARK: SOCKS5

    @Test func socksGreetingWithoutUsernamePasswordIsRefusedBeforeAnyStreamOpens() throws {
        let harness = try ProxySessionTestHarness.start()
        defer { harness.stop() }
        let client = harness.makeClient()
        defer { client.cancel() }

        client.send(Data([0x05, 0x01, 0x00]) + Self.socksConnectRequest(host: "example.test", port: 80))

        #expect(client.waitForReceived { _, closed in closed })
        #expect(client.receivedData == Data([0x05, 0xFF]))
        #expect(harness.rpcClient.openedTargets.isEmpty)
    }

    @Test func socksWithWrongPasswordIsRefusedBeforeAnyStreamOpens() throws {
        let harness = try ProxySessionTestHarness.start()
        defer { harness.stop() }
        let client = harness.makeClient()
        defer { client.cancel() }

        client.send(
            Data([0x05, 0x01, 0x02])
                + Self.socksAuthentication(username: harness.credential.username, password: "wrong")
                + Self.socksConnectRequest(host: "example.test", port: 80)
        )

        #expect(client.waitForReceived { _, closed in closed })
        #expect(client.receivedData == Data([0x05, 0x02, 0x01, 0x01]))
        #expect(harness.rpcClient.openedTargets.isEmpty)
    }

    @Test func socksWithCredentialOpensStreamAndRelaysBytes() throws {
        let harness = try ProxySessionTestHarness.start()
        defer { harness.stop() }
        let client = harness.makeClient()
        defer { client.cancel() }

        client.send(Data([0x05, 0x01, 0x02]))
        #expect(client.waitForReceived { data, _ in data.count >= 2 })
        #expect(client.receivedData == Data([0x05, 0x02]))

        client.send(Self.socksAuthentication(
            username: harness.credential.username,
            password: harness.credential.password
        ))
        #expect(client.waitForReceived { data, _ in data.count >= 4 })
        #expect(client.receivedData == Data([0x05, 0x02, 0x01, 0x00]))

        client.send(Self.socksConnectRequest(host: "example.test", port: 80))
        let handshakeReply = Data([0x05, 0x02, 0x01, 0x00]) + Self.socksSuccessReply
        #expect(client.waitForReceived { data, _ in data.count >= handshakeReply.count })
        #expect(client.receivedData == handshakeReply)

        client.send(Data("ping".utf8))
        #expect(client.waitForReceived { data, _ in data == handshakeReply + Data("ping".utf8) })
        #expect(harness.rpcClient.openedTargets == ["example.test:80"])
        #expect(!client.isClosed)
    }

    // MARK: HTTP CONNECT

    @Test func connectWithoutProxyAuthorizationIsRefusedBeforeAnyStreamOpens() throws {
        let harness = try ProxySessionTestHarness.start()
        defer { harness.stop() }
        let client = harness.makeClient()
        defer { client.cancel() }

        client.send(Self.connectRequest(authority: "example.test:443", proxyAuthorization: nil))

        #expect(client.waitForReceived { _, closed in closed })
        let response = String(decoding: client.receivedData, as: UTF8.self)
        #expect(response.hasPrefix("HTTP/1.1 407 "))
        #expect(response.contains("\r\nProxy-Authenticate: Basic realm=\"cmux\"\r\n"))
        #expect(harness.rpcClient.openedTargets.isEmpty)
    }

    @Test func connectWithWrongProxyAuthorizationIsRefusedBeforeAnyStreamOpens() throws {
        let harness = try ProxySessionTestHarness.start()
        defer { harness.stop() }
        let client = harness.makeClient()
        defer { client.cancel() }

        client.send(Self.connectRequest(
            authority: "example.test:443",
            proxyAuthorization: Self.basicAuthorization(username: harness.credential.username, password: "wrong")
        ))

        #expect(client.waitForReceived { _, closed in closed })
        #expect(String(decoding: client.receivedData, as: UTF8.self).hasPrefix("HTTP/1.1 407 "))
        #expect(harness.rpcClient.openedTargets.isEmpty)
    }

    @Test func connectWithProxyAuthorizationOpensStreamAndRelaysBytes() throws {
        let harness = try ProxySessionTestHarness.start()
        defer { harness.stop() }
        let client = harness.makeClient()
        defer { client.cancel() }

        client.send(Self.connectRequest(
            authority: "example.test:443",
            proxyAuthorization: Self.basicAuthorization(
                username: harness.credential.username,
                password: harness.credential.password
            )
        ))
        let marker = Data("\r\n\r\n".utf8)
        #expect(client.waitForReceived { data, _ in data.range(of: marker) != nil })
        let established = client.receivedData
        #expect(String(decoding: established, as: UTF8.self).hasPrefix("HTTP/1.1 200 Connection Established\r\n"))

        client.send(Data("ping".utf8))
        #expect(client.waitForReceived { data, _ in data == established + Data("ping".utf8) })
        #expect(harness.rpcClient.openedTargets == ["example.test:443"])
        #expect(!client.isClosed)
    }

    // MARK: Network.framework proxy client (the stack WKWebView uses)

    enum ProxyKind: String, CaseIterable, Sendable {
        case socks5
        case httpConnect
    }

    @Test(arguments: ProxyKind.allCases)
    func proxyConfigurationWithCredentialReachesTarget(_ kind: ProxyKind) async throws {
        let harness = try ProxySessionTestHarness.start(
            rpcClient: ProxyStreamTestRPCClient(cannedReply: Self.cannedHTTPResponse)
        )
        defer { harness.stop() }

        let (data, response) = try await Self.fetch(through: harness, kind: kind, applyCredential: true)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "ok")
        #expect(harness.rpcClient.openedTargets == ["example.test:80"])
    }

    @Test(arguments: ProxyKind.allCases)
    func proxyConfigurationWithoutCredentialIsRefused(_ kind: ProxyKind) async throws {
        let harness = try ProxySessionTestHarness.start(
            rpcClient: ProxyStreamTestRPCClient(cannedReply: Self.cannedHTTPResponse)
        )
        defer { harness.stop() }

        let statusCode: Int?
        do {
            let (_, response) = try await Self.fetch(through: harness, kind: kind, applyCredential: false)
            statusCode = (response as? HTTPURLResponse)?.statusCode
        } catch {
            statusCode = nil
        }

        #expect(statusCode != 200)
        #expect(harness.rpcClient.openedTargets.isEmpty)
    }

    // MARK: Helpers

    private static let cannedHTTPResponse = Data(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8
    )

    private static func fetch(
        through harness: ProxySessionTestHarness,
        kind: ProxyKind,
        applyCredential: Bool
    ) async throws -> (Data, URLResponse) {
        let proxy = switch kind {
        case .socks5: ProxyConfiguration(socksv5Proxy: harness.endpoint)
        case .httpConnect: ProxyConfiguration(httpCONNECTProxy: harness.endpoint)
        }
        if applyCredential {
            proxy.applyCredential(username: harness.credential.username, password: harness.credential.password)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [proxy]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        // Without the delegate, the refused CONNECT case asks the user for a
        // proxy password in a system dialog.
        let session = URLSession(
            configuration: configuration,
            delegate: ManagedProxySessionDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        return try await session.data(from: URL(string: "http://example.test/")!)
    }

    private static func socksAuthentication(username: String, password: String) -> Data {
        let usernameBytes = Array(username.utf8)
        let passwordBytes = Array(password.utf8)
        return Data([0x01, UInt8(usernameBytes.count)] + usernameBytes + [UInt8(passwordBytes.count)] + passwordBytes)
    }

    private static func socksConnectRequest(host: String, port: UInt16) -> Data {
        let hostBytes = Array(host.utf8)
        return Data(
            [0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)] + hostBytes + [UInt8(port >> 8), UInt8(port & 0xFF)]
        )
    }

    private static func basicAuthorization(username: String, password: String) -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    private static func connectRequest(authority: String, proxyAuthorization: String?) -> Data {
        var text = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
        if let proxyAuthorization {
            text += "Proxy-Authorization: \(proxyAuthorization)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }
}

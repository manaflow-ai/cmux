import CryptoKit
import Foundation
import Network
import Testing

@testable import CmuxIrohTransport
@testable import CmuxIrxTransport

/// Reproduces the deterministic first-mint failure from the 2026-08-26 irx
/// soak (issue #10924): the credential autopilot's mint POST rides a pooled
/// keep-alive connection that the broker edge closed while the client slept
/// its ~3-4 minute refresh interval. The next POST writes into the dead
/// socket, the first read returns POSIX 54 (ECONNRESET), and URLSession
/// surfaces NSURLErrorNetworkConnectionLost (-1005) without a transparent
/// retry because a POST with bytes written is not retried (Apple QA1941).
///
/// The in-process server below makes that sequence exact: it serves the first
/// mint on a keep-alive connection, then resets that same connection when the
/// next request arrives on it, then serves normally on fresh connections.
@Suite(.serialized)
struct IrxBrokerMintRetryTests {
    /// The soak-observed failure: the second mint of a session lands on the
    /// stale pooled connection. The broker service must classify the -1005,
    /// retry the idempotent mint once immediately on the fresh connection the
    /// purged pool now provides, and succeed within the same cycle instead of
    /// surfacing `mint-failed connectivity` and waiting for the ~64s outer
    /// autopilot retry.
    @Test
    func mintRetriesOnceWhenPooledConnectionDiesBetweenCycles() async throws {
        let server = try await IrxStaleKeepAliveHTTPServer.start { requestIndex in
            requestIndex == 1 ? .resetConnection : .respond
        }
        defer { server.stop() }
        let journal = IrxJournal(subsystem: "dev.cmux.irx-tests", category: "mint-retry")
        let service = try Self.makeBrokerService(port: server.port, journal: journal)
        server.mintResponseBody = Self.mintResponseBody(
            endpointIDHex: Self.testIdentity.endpointIDHex
        )

        let first = try await service.mintRelayCredentials()
        #expect(!first.isEmpty)

        // Second cycle: first attempt hits the reset pooled connection. The
        // fix retries once, immediately, on a fresh connection.
        let second = try await service.mintRelayCredentials()
        #expect(!second.isEmpty)

        // Exactly one retry: 1 (first mint) + 2 (failed attempt + retry).
        #expect(server.requestCount == 3)

        let retried = journal.tail().filter { $0.event == "relay-mint-retried" }
        #expect(retried.count == 1)
        #expect(
            retried.first?.attributes["error"]?.contains("networkConnectionLost(-1005)")
                == true
        )
    }

    /// When the immediate retry also fails, the surfaced error (which the
    /// autopilot journals as `mint-failed a_error`) must carry the underlying
    /// NSURLError classification instead of collapsing to bare "connectivity".
    @Test
    func mintFailureCarriesUnderlyingURLErrorCode() async throws {
        let server = try await IrxStaleKeepAliveHTTPServer.start { requestIndex in
            requestIndex == 0 ? .respond : .resetConnection
        }
        defer { server.stop() }
        let journal = IrxJournal(subsystem: "dev.cmux.irx-tests", category: "mint-attrib")
        let service = try Self.makeBrokerService(port: server.port, journal: journal)
        server.mintResponseBody = Self.mintResponseBody(
            endpointIDHex: Self.testIdentity.endpointIDHex
        )

        let first = try await service.mintRelayCredentials()
        #expect(!first.isEmpty)

        do {
            _ = try await service.mintRelayCredentials()
            Issue.record("second mint unexpectedly succeeded; server resets every attempt")
        } catch {
            let description = String(describing: error)
            #expect(
                description.contains("networkConnectionLost(-1005)"),
                "mint failure must attribute the URL error, got: \(description)"
            )
        }

        // One attempt plus exactly one immediate retry, never a retry loop.
        #expect(server.requestCount == 3)
    }

    // MARK: - Fixtures

    private static let testIdentity = IrxIdentity(
        privateKeyData: Curve25519.Signing.PrivateKey().rawRepresentation,
        deviceID: "irx-mint-retry-test-device",
        appInstanceID: "b2fb2f6e-1111-4222-8333-444455556666"
    )

    private static func makeBrokerService(
        port: UInt16,
        journal: IrxJournal
    ) throws -> IrxBrokerService {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("irx-mint-retry-tests-\(UUID().uuidString)")
        guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
            throw IrxBrokerServiceError.invalidIdentity
        }
        return try IrxBrokerService(
            configuration: IrxBrokerService.Configuration(
                baseURL: baseURL,
                clientNamespace: "dev.cmux.irx-tests",
                tag: "irx-tests",
                platform: .ios,
                displayName: nil,
                cacheDirectory: cacheDirectory
            ),
            identity: testIdentity,
            accessTokenPair: { ("test-access-token", "test-refresh-token") },
            journal: journal
        )
    }

    /// A minimal valid `/api/relay/token` bootstrap response: one managed
    /// relay credential bound to the test endpoint plus the signed-policy
    /// triplet the bootstrap path requires (shape-validated only).
    private static func mintResponseBody(endpointIDHex: String) -> Data {
        let now = Int64(Date().timeIntervalSince1970)
        let json = """
            {
              "endpointId": "\(endpointIDHex)",
              "relayCredentials": [
                {
                  "relayUrl": "https://usc1.relay.cmux.dev/",
                  "token": "irx-test-relay-token",
                  "expiresAt": \(now + 300),
                  "refreshAfter": \(now + 240),
                  "ttlSeconds": 300
                }
              ],
              "policy": "eyJhbGciOiJFZERTQSJ9.eyJwb2xpY3kiOjF9.c2lnbmF0dXJl",
              "preference": { "mode": "automatic" },
              "preferenceRevision": 1
            }
            """
        return Data(json.utf8)
    }
}

/// Minimal in-process HTTP/1.1 keep-alive server whose per-request script can
/// reset the underlying TCP connection instead of answering, which is how a
/// broker edge's silent idle close surfaces to the client: the request bytes
/// are written, then the first read fails with ECONNRESET.
final class IrxStaleKeepAliveHTTPServer: @unchecked Sendable {
    enum RequestAction: Sendable {
        case respond
        case resetConnection
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "irx-stale-keepalive-http-server")
    private let lock = NSLock()
    private let action: @Sendable (Int) -> RequestAction
    private var servedRequestCount = 0
    private var openConnections: [NWConnection] = []
    private var responseBody = Data("{}".utf8)

    /// Bound loopback port; valid once the listener reports ready.
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return servedRequestCount
    }

    var mintResponseBody: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return responseBody
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            responseBody = newValue
        }
    }

    static func start(
        action: @escaping @Sendable (Int) -> RequestAction
    ) async throws -> IrxStaleKeepAliveHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: .any
        )
        let listener = try NWListener(using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            let server = IrxStaleKeepAliveHTTPServer(listener: listener, action: action)
            let resumer = OnceResumer(continuation: continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumer.resume(.success(server))
                case let .failed(error):
                    resumer.resume(.failure(error))
                default:
                    break
                }
            }
            listener.start(queue: server.queue)
        }
    }

    /// Resumes a checked continuation at most once across listener callbacks.
    private final class OnceResumer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<IrxStaleKeepAliveHTTPServer, any Error>?

        init(continuation: CheckedContinuation<IrxStaleKeepAliveHTTPServer, any Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<IrxStaleKeepAliveHTTPServer, any Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    private init(
        listener: NWListener,
        action: @escaping @Sendable (Int) -> RequestAction
    ) {
        self.listener = listener
        self.action = action
        listener.newConnectionHandler = { [weak self] connection in
            self?.adopt(connection)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let connections = openConnections
        openConnections = []
        lock.unlock()
        for connection in connections {
            connection.cancel()
        }
    }

    private func adopt(_ connection: NWConnection) {
        lock.lock()
        openConnections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        receiveLoop(connection, buffer: Data())
    }

    private func receiveLoop(_ connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 128 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return }
            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            let stillOpen = self.drainCompleteRequests(&buffer, on: connection)
            if stillOpen, !isComplete {
                self.receiveLoop(connection, buffer: buffer)
            }
        }
    }

    /// Consumes every complete HTTP request in `buffer`, applying the script.
    /// Returns false once the connection has been reset.
    private func drainCompleteRequests(
        _ buffer: inout Data, on connection: NWConnection
    ) -> Bool {
        while let request = Self.completeRequestLength(in: buffer) {
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + request)
            lock.lock()
            let index = servedRequestCount
            servedRequestCount += 1
            let body = responseBody
            lock.unlock()
            switch action(index) {
            case .respond:
                let head =
                    "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: application/json\r\n"
                    + "Content-Length: \(body.count)\r\n"
                    + "Connection: keep-alive\r\n\r\n"
                connection.send(
                    content: Data(head.utf8) + body,
                    completion: .contentProcessed { _ in }
                )
            case .resetConnection:
                // RST, exactly like the edge tearing down the idle pooled
                // connection: the client's written request is never answered
                // and its next read fails with ECONNRESET (POSIX 54).
                connection.forceCancel()
                return false
            }
        }
        return true
    }

    /// Total byte length of the first complete request in `buffer`, or nil.
    private static func completeRequestLength(in buffer: Data) -> Int? {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = buffer[buffer.startIndex ..< headerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        var contentLength = 0
        for line in headerText.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                    == "content-length",
                let value = Int(parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            contentLength = value
        }
        let total = (headerRange.upperBound - buffer.startIndex) + contentLength
        return buffer.count >= total ? total : nil
    }
}

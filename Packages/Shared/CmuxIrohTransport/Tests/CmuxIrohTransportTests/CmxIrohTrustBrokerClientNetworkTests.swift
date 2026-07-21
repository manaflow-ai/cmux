import Foundation
import Testing
@testable import CmuxIrohTransport

extension CmxIrohTrustBrokerClientTests {
    @Test
    func rateLimitRetainsOnlyBoundedCanonicalRetryAfterSeconds() async throws {
        for (header, expected) in [
            ("600", CmxIrohTrustBrokerClientError.rateLimited(
                code: "rate_limited",
                retryAfterSeconds: 600
            )),
            ("86400", CmxIrohTrustBrokerClientError.rateLimited(
                code: "rate_limited",
                retryAfterSeconds: 86_400
            )),
            ("0", CmxIrohTrustBrokerClientError.rejected(
                statusCode: 429,
                code: "rate_limited"
            )),
            ("86401", CmxIrohTrustBrokerClientError.rejected(
                statusCode: 429,
                code: "rate_limited"
            )),
            ("0600", CmxIrohTrustBrokerClientError.rejected(
                statusCode: 429,
                code: "rate_limited"
            )),
        ] {
            let transport = RecordingBrokerTransport(responses: [
                .json(
                    status: 429,
                    body: #"{"error":"rate_limited","token":"do-not-copy"}"#,
                    headers: ["Retry-After": header]
                ),
            ])
            let client = try makeNetworkClient(transport: transport)

            await #expect(throws: expected) {
                _ = try await client.discover()
            }
        }
    }

    @Test
    func rateLimitSuppressesConcurrentSameRouteRequestsWithoutBlockingOtherRoutes() async throws {
        let transport = RouteRecordingBrokerTransport(responsesByPath: [
            "/api/devices/iroh": [
                .json(
                    status: 429,
                    body: #"{"error":"rate_limited"}"#,
                    headers: ["Retry-After": "600"]
                ),
            ],
            "/api/relay/preferences": [
                .json(
                    status: 200,
                    body: #"{"preference":{"mode":"automatic"},"preferenceRevision":0}"#
                ),
            ],
        ])
        let client = try makeNetworkClient(transport: transport)

        await #expect(throws: CmxIrohTrustBrokerClientError.rateLimited(
            code: "rate_limited",
            retryAfterSeconds: 600
        )) {
            _ = try await client.discover()
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 2 {
                group.addTask {
                    do {
                        _ = try await client.discover()
                        Issue.record("Expected the active route cooldown to reject discovery")
                    } catch {}
                }
            }
        }

        let preference = try await client.relayPreference()
        #expect(preference.preference == .automatic)
        #expect(await transport.requests().map { $0.url?.path } == [
            "/api/devices/iroh",
            "/api/relay/preferences",
        ])
    }

    @Test
    func missingAuthFailsBeforeAnyNetworkRequest() async throws {
        let transport = RecordingBrokerTransport(responses: [])
        let client = try CmxIrohTrustBrokerClient(
            baseURL: try #require(URL(string: "https://cmux.example")),
            tokenSource: CmxIrohBrokerTokenSource(
                accessToken: { nil },
                refreshToken: { "refresh" }
            ),
            transport: transport
        )
        await #expect(throws: CmxIrohTrustBrokerClientError.missingAuthentication) {
            _ = try await client.discover()
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test
    func cleartextRemoteOriginIsRejected() throws {
        #expect(throws: CmxIrohTrustBrokerClientError.invalidBaseURL) {
            _ = try CmxIrohTrustBrokerClient(
                baseURL: #require(URL(string: "http://cmux.example")),
                tokenSource: Self.networkTokenSource,
                transport: RecordingBrokerTransport(responses: [])
            )
        }
    }

    @Test
    func availabilityURLErrorMapsToConnectivityFailure() async throws {
        let transport = RecordingBrokerTransport(
            responses: [],
            failure: .notConnectedToInternet
        )
        let client = try makeNetworkClient(transport: transport)

        await #expect(throws: CmxIrohTrustBrokerClientError.connectivity) {
            _ = try await client.discover()
        }
    }

    @Test
    func tlsValidationURLErrorRemainsTerminal() async throws {
        let transport = RecordingBrokerTransport(
            responses: [],
            failure: .serverCertificateUntrusted
        )
        let client = try makeNetworkClient(transport: transport)

        do {
            _ = try await client.discover()
            Issue.record("Expected TLS validation failure")
        } catch let error as URLError {
            #expect(error.code == .serverCertificateUntrusted)
        }
    }

    @Test
    func redirectsNeverForwardBrokerCredentials() async throws {
        for destination in [
            try #require(URL(string: "https://cmux.example/capture")),
            try #require(URL(string: "https://attacker.example/capture")),
        ] {
            BrokerRedirectURLProtocol.reset(destination: destination)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BrokerRedirectURLProtocol.self]
            let client = try CmxIrohTrustBrokerClient(
                baseURL: try #require(URL(string: "https://cmux.example")),
                tokenSource: Self.networkTokenSource,
                transport: CmxIrohURLSessionTransport(configuration: configuration),
                requestTimeout: 0.1
            )

            _ = try? await client.discover()

            #expect(BrokerRedirectURLProtocol.capturedDestinationRequests().isEmpty)
        }
    }

    private func makeNetworkClient(
        transport: any CmxIrohHTTPTransport
    ) throws -> CmxIrohTrustBrokerClient {
        try CmxIrohTrustBrokerClient(
            baseURL: #require(URL(string: "https://cmux.example")),
            tokenSource: Self.networkTokenSource,
            transport: transport
        )
    }

    private static let networkTokenSource = CmxIrohBrokerTokenSource(
        accessToken: { "access" },
        refreshToken: { "refresh" }
    )
}

private actor RouteRecordingBrokerTransport: CmxIrohHTTPTransport {
    enum TestError: Error {
        case invalidRequest
        case unexpectedRequest(String)
    }

    private var responsesByPath: [String: [RecordingBrokerTransport.Response]]
    private var captured: [URLRequest] = []

    init(responsesByPath: [String: [RecordingBrokerTransport.Response]]) {
        self.responsesByPath = responsesByPath
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw TestError.invalidRequest }
        captured.append(request)
        guard var pending = responsesByPath[url.path], !pending.isEmpty else {
            throw TestError.unexpectedRequest(url.path)
        }
        let response = pending.removeFirst()
        responsesByPath[url.path] = pending
        guard let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
                .merging(response.headers) { _, new in new }
        ) else {
            throw TestError.invalidRequest
        }
        return (response.body, http)
    }

    func requests() -> [URLRequest] { captured }
}

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
    func rateLimitSourceUsesOnlyCanonicalValues() async throws {
        let cases = [
            (
                #"{"error":"rate_limited","source":"ingress_ip"}"#,
                "rate_limited:ingress_ip"
            ),
            (
                #"{"error":"rate_limited","source":"device_budget"}"#,
                "rate_limited:device_budget"
            ),
            (
                #"{"error":"rate_limited","source":"account_budget"}"#,
                "rate_limited:account_budget"
            ),
            (
                #"{"error":"rate_limited","source":"auth_provider"}"#,
                "rate_limited:auth_provider"
            ),
            (
                #"{"error":"rate_limited","source":"attacker\nforged"}"#,
                "rate_limited"
            ),
            (
                #"{"error":"rate_limited","source":42}"#,
                "rate_limited"
            ),
            (
                #"{"error":"rate_limited","source":{"layer":"ingress_ip"}}"#,
                "rate_limited"
            ),
        ]

        for (body, expectedCode) in cases {
            let transport = RecordingBrokerTransport(responses: [
                .json(
                    status: 429,
                    body: body,
                    headers: ["Retry-After": "60"]
                ),
            ])
            let client = try makeNetworkClient(transport: transport)

            await #expect(throws: CmxIrohTrustBrokerClientError.rateLimited(
                code: expectedCode,
                retryAfterSeconds: 60
            )) {
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
    func rateLimitIsScopedByOperationWhenMethodsShareAPath() async throws {
        let transport = RouteRecordingBrokerTransport(responsesByPath: [
            "/api/devices/iroh": [
                .json(
                    status: 429,
                    body: #"{"error":"rate_limited"}"#,
                    headers: ["Retry-After": "600"]
                ),
                .json(
                    status: 200,
                    body: #"{"revoked":true,"lan_rendezvous_rotated":true}"#
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

        try await client.revoke(bindingID: "binding-1")

        await #expect(throws: CmxIrohTrustBrokerClientError.rateLimited(
            code: "cooldown:rate_limited",
            retryAfterSeconds: 600
        )) {
            _ = try await client.discover()
        }
        #expect(await transport.requests().map(\.httpMethod) == ["GET", "DELETE"])
    }

    @Test
    func missingAuthFailsBeforeAnyNetworkRequest() async throws {
        let transport = RecordingBrokerTransport(responses: [])
        let client = try CmxIrohTrustBrokerClient(
            baseURL: try #require(URL(string: "https://cmux.example")),
            tokenSource: CmxIrohBrokerTokenSource(
                credentialPair: { nil }
            ),
            clientNamespace: "legacy",
            transport: transport
        )
        await #expect(throws: CmxIrohTrustBrokerClientError.missingAuthentication) {
            _ = try await client.discover()
        }
        #expect(await transport.requests().isEmpty)
    }

    /// Cancellation is not a network failure: a cancelled caller must observe
    /// `CancellationError`, or retry policies and cached-policy fallbacks keep
    /// working on a cancelled task as though the broker were offline.
    @Test
    func cancelledTokenReadPropagatesCancellationNotConnectivity() async throws {
        let transport = RecordingBrokerTransport(responses: [])
        let client = try CmxIrohTrustBrokerClient(
            baseURL: try #require(URL(string: "https://cmux.example")),
            tokenSource: CmxIrohBrokerTokenSource(
                credentialPair: { throw CancellationError() }
            ),
            clientNamespace: "legacy",
            transport: transport
        )
        await #expect(throws: CancellationError.self) {
            _ = try await client.discover()
        }
        #expect(await transport.requests().isEmpty)
    }

    /// A THROWING token source could not read a coherent pair right now (the
    /// token store is owned by a launch/foreground revalidation, or an expired
    /// access token's re-mint is in flight). That is transient, so it must
    /// classify as `.connectivity` — which retry policies and cached-policy
    /// fallbacks accept — not as terminal `.missingAuthentication`, which
    /// failed every app-launch activation closed while a revalidation ran.
    @Test
    func throwingTokenSourceClassifiesAsConnectivityBeforeAnyNetworkRequest() async throws {
        struct TransientTokenReadError: Error {}
        let transport = RecordingBrokerTransport(responses: [])
        let client = try CmxIrohTrustBrokerClient(
            baseURL: try #require(URL(string: "https://cmux.example")),
            tokenSource: CmxIrohBrokerTokenSource(
                credentialPair: { throw TransientTokenReadError() }
            ),
            clientNamespace: "legacy",
            transport: transport
        )
        await #expect(throws: CmxIrohTrustBrokerClientError.connectivity(nil)) {
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
                clientNamespace: "legacy",
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

        let expected = CmxIrohTrustBrokerClientError.connectivity(
            CmxIrohBrokerConnectivityCause(
                urlErrorCode: URLError.Code.notConnectedToInternet.rawValue
            )
        )
        #expect(String(describing: expected) == "connectivity(notConnectedToInternet(-1009))")
        await #expect(throws: expected) {
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
                clientNamespace: "legacy",
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
            clientNamespace: "legacy",
            transport: transport
        )
    }

    private static let networkTokenSource = CmxIrohBrokerTokenSource(
        credentialPair: {
            CmxIrohBrokerCredentials(accessToken: "access", refreshToken: "refresh")
        }
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

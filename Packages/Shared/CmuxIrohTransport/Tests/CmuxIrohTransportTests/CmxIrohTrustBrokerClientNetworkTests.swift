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
            ("0", CmxIrohTrustBrokerClientError.rejected(
                statusCode: 429,
                code: "rate_limited"
            )),
            ("3601", CmxIrohTrustBrokerClientError.rejected(
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
        transport: RecordingBrokerTransport
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

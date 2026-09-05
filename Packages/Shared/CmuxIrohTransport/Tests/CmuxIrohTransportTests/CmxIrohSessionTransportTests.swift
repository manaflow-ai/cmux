import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite(.serialized)
struct CmxIrohSessionTransportTests {
    @Test
    func bootstrapsOnceThenUsesOnlyTheSessionTicket() async throws {
        let transport = SessionRecordingTransport(responsesByPath: [
            "/v1/iroh/session": [
                .json(status: 201, body: Self.sessionResponse),
            ],
            "/api/relay/preferences": [
                .json(status: 200, body: Self.preferenceResponse),
                .json(status: 200, body: Self.preferenceResponse),
            ],
        ])
        let client = try Self.makeClient(transport: transport)

        _ = try await client.relayPreference()
        _ = try await client.relayPreference()

        let requests = await transport.requests()
        #expect(requests.map { $0.url?.path } == [
            "/v1/iroh/session",
            "/api/relay/preferences",
            "/api/relay/preferences",
        ])
        let bootstrap = try #require(requests[0])
        #expect(bootstrap.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(bootstrap.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh")
        #expect(bootstrap.value(forHTTPHeaderField: "X-Cmux-Iroh-Session-Ticket") == nil)
        let firstRequest = try #require(requests[1])
        let secondRequest = try #require(requests[2])
        #expect(firstRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(firstRequest.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == nil)
        #expect(
            firstRequest.value(forHTTPHeaderField: "X-Cmux-Iroh-Session-Ticket")
                == "ticket-1"
        )
        #expect(
            secondRequest.value(forHTTPHeaderField: "X-Cmux-Iroh-Session-Ticket")
                == "ticket-1"
        )
    }

    @Test
    func missingSessionRouteFallsBackToLegacyCredentials() async throws {
        let transport = SessionRecordingTransport(responsesByPath: [
            "/v1/iroh/session": [
                .json(status: 404, body: #"{"error":"not_found"}"#),
            ],
            "/api/relay/preferences": [
                .json(status: 200, body: Self.preferenceResponse),
            ],
        ])
        let client = try Self.makeClient(transport: transport)

        _ = try await client.relayPreference()

        let requests = await transport.requests()
        #expect(requests.count == 2)
        let legacy = try #require(requests.last)
        #expect(legacy.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(legacy.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh")
        #expect(legacy.value(forHTTPHeaderField: "X-Cmux-Iroh-Session-Ticket") == nil)
    }

    @Test
    func concurrentFirstRequestsShareOneBootstrap() async throws {
        let transport = SessionRecordingTransport(responsesByPath: [
            "/v1/iroh/session": [
                .json(status: 201, body: Self.sessionResponse),
            ],
            "/api/relay/preferences": Array(
                repeating: .json(status: 200, body: Self.preferenceResponse),
                count: 3
            ),
        ])
        let client = try Self.makeClient(transport: transport)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 3 {
                group.addTask {
                    _ = try? await client.relayPreference()
                }
            }
        }

        let requests = await transport.requests()
        #expect(requests.filter { $0.url?.path == "/v1/iroh/session" }.count == 1)
        #expect(requests.filter { $0.url?.path == "/api/relay/preferences" }.count == 3)
    }

    private static func makeClient(
        transport: any CmxIrohHTTPTransport
    ) throws -> CmxIrohTrustBrokerClient {
        try CmxIrohTrustBrokerClient(
            baseURL: #require(URL(string: "https://cmux.example")),
            tokenSource: CmxIrohBrokerTokenSource(
                credentialPair: {
                    CmxIrohBrokerCredentials(accessToken: "access", refreshToken: "refresh")
                }
            ),
            clientNamespace: "dev.cmux.ios",
            sessionConfiguration: CmxIrohSessionConfiguration(
                deviceID: "device-1",
                appInstanceID: "instance-1",
                clientNamespace: "dev.cmux.ios",
                tag: "test",
                platform: .ios
            ),
            transport: transport
        )
    }

    private static let sessionResponse = #"""
    {
      "ticket":"ticket-1",
      "sessionId":"session-1",
      "accountId":"account-1",
      "expiresAt":"2099-01-01T00:15:00.000Z",
      "renewAfter":"2099-01-01T00:10:00.000Z"
    }
    """#

    private static let preferenceResponse = #"""
    {
      "preference":{"mode":"automatic"},
      "preferenceRevision":0
    }
    """#
}

private actor SessionRecordingTransport: CmxIrohHTTPTransport {
    struct Response: Sendable {
        let status: Int
        let body: Data

        static func json(status: Int, body: String) -> Self {
            Self(status: status, body: Data(body.utf8))
        }
    }

    private var responsesByPath: [String: [Response]]
    private var captured: [URLRequest] = []

    init(responsesByPath: [String: [Response]]) {
        self.responsesByPath = responsesByPath
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        captured.append(request)
        guard var responses = responsesByPath[url.path], !responses.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        let response = responses.removeFirst()
        responsesByPath[url.path] = responses
        let http = try #require(HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        return (response.body, http)
    }

    func requests() -> [URLRequest] { captured }
}

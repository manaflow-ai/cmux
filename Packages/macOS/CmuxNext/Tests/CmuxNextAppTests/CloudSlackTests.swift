@testable import CmuxNextCloud
import Foundation
import Testing

@Suite(.serialized)
struct CloudSlackTests {
    nonisolated final class SlackAPI: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var seen: [URLRequest] = []

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.seen.append(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                  headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"connected":false,"teams":[]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func client() throws -> CloudAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlackAPI.self]
        return CloudAPIClient.slack(baseURL: try #require(URL(string: "https://platform.standin.invalid")),
                                    accessToken: { "person-access" }, teamID: "team-selected",
                                    session: URLSession(configuration: configuration))
    }

    @Test func slackRequestsUseTheSelectedTeamAndWorkerAuth() async throws {
        SlackAPI.seen = []
        let data = try await client().slackRequest(method: "GET")
        #expect(data == Data(#"{"connected":false,"teams":[]}"#.utf8))
        let request = try #require(SlackAPI.seen.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://platform.standin.invalid/v1/slack/connection")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer person-access")
        #expect(request.value(forHTTPHeaderField: "x-cmux-team") == "team-selected")
        #expect(request.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == nil)
    }
}

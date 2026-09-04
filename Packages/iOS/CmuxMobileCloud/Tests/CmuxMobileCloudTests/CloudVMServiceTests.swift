import Foundation
import Testing
@testable import CmuxMobileCloud

@Suite(.serialized)
struct CloudVMServiceTests {
    @Test func listForwardsSelectedTeamContext() async throws {
        TeamHeaderURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TeamHeaderURLProtocol.self]
        let service = CloudVMService(
            baseURL: "https://cmux.example",
            tokens: .fixed(accessToken: "access", refreshToken: "refresh", teamID: "team-123"),
            sessionConfiguration: configuration
        )

        let machines = try await service.listMachines()

        #expect(machines.isEmpty)
        #expect(TeamHeaderURLProtocol.capturedRequest()?.value(forHTTPHeaderField: "X-Cmux-Team-Id") == "team-123")
    }
}

private final class TeamHeaderURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var request: URLRequest?

    static func reset() {
        lock.withLock { request = nil }
    }

    static func capturedRequest() -> URLRequest? {
        lock.withLock { request }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.withLock { Self.request = request }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"vms":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

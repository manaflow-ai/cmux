import Foundation
import StackAuth
import Testing
@testable import CmuxAuthRuntime

@Suite(.serialized)
struct StackAuthClientTests {
    @Test func failedCurrentUserFetchDoesNotLookLikeEmptyTeams() async throws {
        StackAuthClientURLProtocol.reset()
        URLProtocol.registerClass(StackAuthClientURLProtocol.self)
        defer { URLProtocol.unregisterClass(StackAuthClientURLProtocol.self) }

        let stack = StackClientApp(
            projectId: "test-project",
            publishableClientKey: "test-key",
            baseUrl: "https://cmux-stack-auth.test",
            tokenStore: .explicit(
                accessToken: "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTl9.signature",
                refreshToken: "refresh-token"
            ),
            noAutomaticPrefetch: true
        )
        let client = StackAuthClient(stack: stack)

        await #expect(throws: UserNotSignedInError.self) {
            _ = try await client.listTeams()
        }
        #expect(StackAuthClientURLProtocol.recordedPaths == ["/api/v1/users/me"])
    }
}

private final class StackAuthClientURLProtocol: URLProtocol, @unchecked Sendable {
    // URLProtocol's synchronous callback must record before it reports completion.
    private static let recorder = StackAuthClientURLProtocolRecorder()

    static var recordedPaths: [String] { recorder.paths }

    static func reset() {
        recorder.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cmux-stack-auth.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.recorder.record(path: url.path)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 400,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"message":"temporary failure"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class StackAuthClientURLProtocolRecorder: @unchecked Sendable {
    // The lock protects the synchronous URLProtocol callback and test snapshot.
    private let lock = NSLock()
    private var storedPaths: [String] = []

    var paths: [String] {
        lock.withLock { storedPaths }
    }

    func reset() {
        lock.withLock { storedPaths = [] }
    }

    func record(path: String) {
        lock.withLock { storedPaths.append(path) }
    }
}

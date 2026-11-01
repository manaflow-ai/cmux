import Foundation
import StackAuth
import Testing
@testable import CmuxAuthRuntime

/// Stack's `getUser(or: .returnNull)` answers nil for any failure, including a
/// failed `/users/me`. A team list must not turn that into "no teams": the
/// coordinator would record an empty membership as loaded and never retry, so
/// a paid account looks teamless until it signs in again (#20051).
///
/// Stack raises its own not-signed-in error when no token resolves or the
/// user request fails; `listTeams` adds its own only for an unreadable reply.
/// Any error is correct; an empty list is the bug.
@Suite(.serialized) struct StackAuthClientTeamListTests {
    @Test func listTeamsThrowsWhenStackHasNoSession() async {
        let client = Self.client(tokenStore: .memory)

        await #expect(throws: (any Error).self) {
            _ = try await client.listTeams()
        }
    }

    @Test func listTeamsThrowsWhenTokenRefreshFails() async {
        // Not a fresh JWT, so Stack refreshes it, and the stub answers 503.
        let client = Self.client(tokenStore: .explicit(accessToken: "access", refreshToken: "refresh"))

        await #expect(throws: (any Error).self) {
            _ = try await client.listTeams()
        }
        #expect(StackUnavailableURLProtocol.requestedPaths.contains { $0.hasSuffix("/auth/oauth/token") })
    }

    @Test func listTeamsThrowsWhenUserRequestFails() async {
        // A fresh token skips the refresh, so the request reaches `/users/me`,
        // which the stub answers with 503.
        let client = Self.client(tokenStore: .explicit(accessToken: Self.freshAccessToken(), refreshToken: "refresh"))

        await #expect(throws: UserNotSignedInError.self) {
            _ = try await client.listTeams()
        }
        #expect(StackUnavailableURLProtocol.requestedPaths.contains { $0.hasSuffix("/users/me") })
    }

    private static func client(tokenStore: TokenStoreInit) -> StackAuthClient {
        StackUnavailableURLProtocol.install()
        return StackAuthClient(
            config: AuthConfig(environment: .production),
            tokenStore: tokenStore,
            baseURL: "https://\(StackUnavailableURLProtocol.host)",
            noAutomaticPrefetch: true
        )
    }

    /// An unsigned JWT issued now and valid for an hour, which Stack treats as
    /// fresh enough to send without refreshing.
    private static func freshAccessToken() -> String {
        let now = Int(Date().timeIntervalSince1970)
        func segment(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return [
            segment(#"{"alg":"none","typ":"JWT"}"#),
            segment(#"{"sub":"user","iat":\#(now),"exp":\#(now + 3600)}"#),
            "signature",
        ].joined(separator: ".")
    }
}

/// Answers every request to its own host with 503, so Stack's requests fail
/// without real network and without its connection-error retry backoff.
final class StackUnavailableURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "stack-unavailable.test"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var isInstalled = false

    static var requestedPaths: [String] {
        lock.withLock { paths }
    }

    static func install() {
        lock.withLock {
            paths = []
            guard !isInstalled else { return }
            isInstalled = true
            URLProtocol.registerClass(StackUnavailableURLProtocol.self)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.paths.append(request.url?.path ?? "") }
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

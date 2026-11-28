import Foundation
import Testing
@testable import CmuxMobileLive

/// A connection the phone's network left behind: every request on it fails with the `URLError` code its last path
/// component names (`v1/fail/-1001`), the way Leo's phone's cloud calls failed while the link reconnected
/// (2026-11-27: 2,891 Wi-Fi/cellular path changes in 15 minutes, discovery -1001, presence "Socket is not connected").
final class LeftBehindConnection: URLProtocol {
    static let sent = SentCount()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.sent.add()
        let code = Int(request.url?.lastPathComponent ?? "") ?? URLError.Code.timedOut.rawValue
        client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
    }
    override func stopLoading() {}
}

/// A fresh connection: the service answers 200.
final class FreshConnection: URLProtocol {
    static let sent = SentCount()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.sent.add()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SentCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// After a request fails the way a stale pooled connection fails, LiveAPI moves to a fresh session, and sends an
/// idempotent request (or one that never left) there again once: cloud calls keep working through a reconnect storm.
@Suite(.serialized) struct LiveAPIStaleConnectionTests {
    static func session(_ protocolClass: AnyClass) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return URLSession(configuration: configuration)
    }

    /// An API whose first session is a left-behind connection and whose every renewal is a fresh one.
    static func api() throws -> (LiveAPI, APISessions) {
        let sessions = APISessions(session(LeftBehindConnection.self), make: { session(FreshConnection.self) })
        let api = LiveAPI(baseURL: try #require(URL(string: "https://cmux-mobile-api-dev.debussy.workers.dev")),
                          sessions: sessions) { _ in "token" }
        return (api, sessions)
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost])
    func aGetOnAStaleConnectionIsAnsweredOnAFreshOne(code: URLError.Code) async throws {
        let (api, sessions) = try Self.api()
        let fresh = FreshConnection.sent.count
        let data = try await api.call("GET", "v1/fail/\(code.rawValue)")
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        #expect(sessions.renewals == 1)
        #expect(FreshConnection.sent.count == fresh + 1)
    }

    @Test func laterRequestsSkipTheStaleSession() async throws {
        let (api, sessions) = try Self.api()
        _ = try await api.call("GET", "v1/fail/\(URLError.Code.timedOut.rawValue)")
        let stale = LeftBehindConnection.sent.count
        _ = try await api.call("GET", "v1/me/devices")
        _ = try await api.call("POST", "v1/teams/t/invites", body: ["email": "a@b.c"])
        #expect(LeftBehindConnection.sent.count == stale)
        #expect(sessions.renewals == 1)
    }

    @Test func aPostThatMayHaveLeftIsNotSentTwice() async throws {
        let (api, sessions) = try Self.api()
        let fresh = FreshConnection.sent.count
        await #expect(throws: URLError.self) {
            _ = try await api.call("POST", "v1/fail/\(URLError.Code.timedOut.rawValue)", body: [:])
        }
        #expect(FreshConnection.sent.count == fresh)
        #expect(sessions.renewals == 1, "the next request still gets a fresh session")
    }

    @Test func aPostThatNeverLeftIsSentAgain() async throws {
        let (api, _) = try Self.api()
        let data = try await api.call("POST", "v1/fail/\(URLError.Code.cannotConnectToHost.rawValue)", body: [:])
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
    }

    @Test func aServiceAnswerIsNotAStaleConnection() async throws {
        let (api, sessions) = try Self.api()
        await #expect(throws: URLError.self) {
            _ = try await api.call("GET", "v1/fail/\(URLError.Code.badServerResponse.rawValue)")
        }
        #expect(sessions.renewals == 0)
    }

    @Test func manyRequestsFailingTogetherRenewOnce() async throws {
        let (api, sessions) = try Self.api()
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 { group.addTask { try await api.call("GET", "v1/fail/\(URLError.Code.timedOut.rawValue)") } }
            for try await _ in group {}
        }
        #expect(sessions.renewals == 1)
    }

    @Test func theFirstTryOfAnIdempotentRequestGivesUpSooner() throws {
        var get = URLRequest(url: try #require(URL(string: "https://example.invalid/v1/me")))
        get.timeoutInterval = 15
        #expect(LiveAPI.firstTry(get).timeoutInterval == LiveAPI.firstTryTimeout)
        var post = get
        post.httpMethod = "POST"
        #expect(LiveAPI.firstTry(post).timeoutInterval == 15)
    }
}

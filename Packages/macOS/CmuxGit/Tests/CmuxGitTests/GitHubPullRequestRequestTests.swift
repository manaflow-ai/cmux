import Foundation
import Testing
@testable import CmuxGit

private final class GitHubPullRequestStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
        let delay: TimeInterval

        init(
            statusCode: Int,
            headers: [String: String] = [:],
            data: Data = Data(),
            delay: TimeInterval = 0
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.data = data
            self.delay = delay
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var activeRequestCount = 0
    nonisolated(unsafe) private static var maximumActiveRequestCount = 0

    static func reset(stubs: [Stub]) {
        lock.lock()
        self.stubs = stubs
        requests = []
        activeRequestCount = 0
        maximumActiveRequestCount = 0
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func maximumConcurrentRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveRequestCount
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.github.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        guard !Self.stubs.isEmpty else {
            Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = Self.stubs.removeFirst()
        Self.requests.append(request)
        Self.activeRequestCount += 1
        Self.maximumActiveRequestCount = max(
            Self.maximumActiveRequestCount,
            Self.activeRequestCount
        )
        Self.lock.unlock()

        let finish: @Sendable () -> Void = { [self] in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: nil,
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)

            Self.lock.lock()
            Self.activeRequestCount -= 1
            Self.lock.unlock()
        }
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: finish)
        } else {
            finish()
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct GitHubPullRequestRequestTests {
    private let endpoint = "repos/manaflow-ai/cmux/pulls?state=all"

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubPullRequestStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func missingCredentialsNeverStartsAnonymousTransport() async {
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, data: Data("[]".utf8)),
        ])
        let service = PullRequestProbeService()

        let response = await service.performRequest(
            session: makeSession(),
            endpoint: endpoint,
            authHeader: nil
        )

        #expect(response == nil)
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().isEmpty)
    }

    @Test func cachedETagRevalidatesAndReusesBodyAfterNotModified() async throws {
        let body = Data("[{\"number\":8175}]".utf8)
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, headers: ["ETag": "\"issue-8175\""], data: body),
            .init(statusCode: 304),
        ])
        let service = PullRequestProbeService()
        let session = makeSession()

        let first = await service.performRequest(
            session: session,
            endpoint: endpoint,
            authHeader: "Bearer test-token"
        )
        let second = await service.performRequest(
            session: session,
            endpoint: endpoint,
            authHeader: "Bearer test-token"
        )

        #expect(first?.statusCode == 200)
        #expect(first?.data == body)
        #expect(second?.statusCode == 200)
        #expect(second?.data == body)
        let requests = GitHubPullRequestStubURLProtocol.capturedRequests()
        #expect(requests.count == 2)
        #expect(try #require(requests.last).value(forHTTPHeaderField: "If-None-Match") == "\"issue-8175\"")
    }

    @Test func changedCredentialDoesNotReuseETagOrCachedBody() async {
        let firstBody = Data("[{\"number\":8175}]".utf8)
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, headers: ["ETag": "\"first-account\""], data: firstBody),
            .init(statusCode: 304),
            .init(statusCode: 304),
        ])
        let coordinator = GitHubPullRequestRequestCoordinator()
        let session = makeSession()

        _ = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer first-account-token",
            sessionOverride: session
        )
        let changedAccountResponse = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer second-account-token",
            sessionOverride: session
        )
        let originalAccountResponse = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer first-account-token",
            sessionOverride: session
        )

        #expect(changedAccountResponse?.statusCode == 304)
        #expect(changedAccountResponse?.data.isEmpty == true)
        #expect(originalAccountResponse?.statusCode == 200)
        #expect(originalAccountResponse?.data == firstBody)
        let requests = GitHubPullRequestStubURLProtocol.capturedRequests()
        #expect(requests.count == 3)
        #expect(requests[1].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests[2].value(forHTTPHeaderField: "If-None-Match") == "\"first-account\"")
    }

    @Test func responseCacheEvictsOldestEndpointAtCountLimit() async {
        let firstEndpoint = "repos/manaflow-ai/cmux/pulls?head=manaflow-ai:first"
        let secondEndpoint = "repos/manaflow-ai/cmux/pulls?head=manaflow-ai:second"
        let thirdEndpoint = "repos/manaflow-ai/cmux/pulls?head=manaflow-ai:third"
        let firstBody = Data("[{\"number\":1}]".utf8)
        let secondBody = Data("[{\"number\":2}]".utf8)
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, headers: ["ETag": "\"first\""], data: firstBody),
            .init(statusCode: 200, headers: ["ETag": "\"second\""], data: secondBody),
            .init(statusCode: 200, headers: ["ETag": "\"third\""], data: Data("[]".utf8)),
            .init(statusCode: 304),
            .init(statusCode: 200, data: firstBody),
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(maximumCachedResponseCount: 2)
        let session = makeSession()

        for endpoint in [firstEndpoint, secondEndpoint, thirdEndpoint] {
            _ = await coordinator.response(
                endpoint: endpoint,
                authHeader: "Bearer test-token",
                sessionOverride: session
            )
        }
        let retained = await coordinator.response(
            endpoint: secondEndpoint,
            authHeader: "Bearer test-token",
            sessionOverride: session
        )
        _ = await coordinator.response(
            endpoint: firstEndpoint,
            authHeader: "Bearer test-token",
            sessionOverride: session
        )

        #expect(retained?.data == secondBody)
        let requests = GitHubPullRequestStubURLProtocol.capturedRequests()
        #expect(requests.count == 5)
        #expect(requests[3].value(forHTTPHeaderField: "If-None-Match") == "\"second\"")
        #expect(requests[4].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func exhaustedRateLimitSuppressesRequestsUntilReset() async {
        let reset = Int(Date().addingTimeInterval(300).timeIntervalSince1970)
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(
                statusCode: 403,
                headers: [
                    "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": String(reset),
                ]
            ),
            .init(statusCode: 200, data: Data("[]".utf8)),
        ])
        let service = PullRequestProbeService()
        let session = makeSession()

        _ = await service.performRequest(
            session: session,
            endpoint: endpoint,
            authHeader: "Bearer test-token"
        )
        let suppressed = await service.performRequest(
            session: session,
            endpoint: "repos/manaflow-ai/cmux/pulls?state=open",
            authHeader: "Bearer test-token"
        )

        #expect(suppressed == nil)
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 1)
    }

    @Test func exhaustedCredentialDoesNotBackOffChangedCredential() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = Int(now.addingTimeInterval(300).timeIntervalSince1970)
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(
                statusCode: 403,
                headers: [
                    "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": String(reset),
                ]
            ),
            .init(statusCode: 200, data: Data("[]".utf8)),
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(now: { now })
        let session = makeSession()

        _ = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer exhausted-token",
            sessionOverride: session
        )
        let changedCredentialResponse = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer available-token",
            sessionOverride: session
        )
        let changedCredentialRetryDate = await coordinator.retryDate()
        let originalCredentialResponse = await coordinator.response(
            endpoint: "repos/manaflow-ai/cmux/pulls?state=open",
            authHeader: "Bearer exhausted-token",
            sessionOverride: session
        )

        #expect(changedCredentialResponse?.statusCode == 200)
        #expect(changedCredentialRetryDate == nil)
        #expect(originalCredentialResponse == nil)
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 2)
    }

    @Test func permissionDeniedResponseDoesNotTriggerPrimaryRateLimitBackoff() async {
        let reset = Int(Date().addingTimeInterval(300).timeIntervalSince1970)
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(
                statusCode: 403,
                headers: [
                    "X-RateLimit-Remaining": "4999",
                    "X-RateLimit-Reset": String(reset),
                ]
            ),
            .init(statusCode: 200, data: Data("[]".utf8)),
        ])
        let service = PullRequestProbeService()
        let session = makeSession()

        _ = await service.performRequest(
            session: session,
            endpoint: endpoint,
            authHeader: "Bearer test-token"
        )
        let subsequent = await service.performRequest(
            session: session,
            endpoint: "repos/manaflow-ai/cmux/pulls?state=open",
            authHeader: "Bearer test-token"
        )

        #expect(subsequent?.statusCode == 200)
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 2)
    }

    @Test(arguments: [403, 429])
    func secondaryRateLimitRetryAfterSuppressesRequestsUntilDeadline(statusCode: Int) async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(
                statusCode: statusCode,
                headers: [
                    "X-RateLimit-Remaining": "4999",
                    "Retry-After": "120",
                ]
            ),
            .init(statusCode: 200, data: Data("[]".utf8)),
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(now: { now })
        let session = makeSession()

        _ = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer test-token",
            sessionOverride: session
        )
        let suppressed = await coordinator.response(
            endpoint: "repos/manaflow-ai/cmux/pulls?state=open",
            authHeader: "Bearer test-token",
            sessionOverride: session
        )

        #expect(suppressed == nil)
        #expect(await coordinator.retryDate() == now.addingTimeInterval(120))
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 1)
    }

    @Test func duplicateEndpointRequestsShareOneInFlightTransport() async {
        let body = Data("[]".utf8)
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, data: body, delay: 0.05),
            .init(statusCode: 200, data: body, delay: 0.05),
        ])
        let service = PullRequestProbeService()
        let session = makeSession()

        async let first = service.performRequest(
            session: session,
            endpoint: endpoint,
            authHeader: "Bearer test-token"
        )
        async let second = service.performRequest(
            session: session,
            endpoint: endpoint,
            authHeader: "Bearer test-token"
        )
        let responses = await [first, second]

        #expect(responses.allSatisfy { $0?.statusCode == 200 && $0?.data == body })
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 1)
    }

    @Test func changedCredentialDoesNotJoinInFlightEndpointRequest() async {
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, data: Data("[]".utf8), delay: 0.05),
            .init(statusCode: 200, data: Data("[]".utf8)),
        ])
        let coordinator = GitHubPullRequestRequestCoordinator()
        let session = makeSession()

        async let first = coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer first-account-token",
            sessionOverride: session
        )
        async let second = coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer second-account-token",
            sessionOverride: session
        )
        _ = await [first, second]

        let requests = GitHubPullRequestStubURLProtocol.capturedRequests()
        #expect(requests.count == 2)
        #expect(Set(requests.compactMap {
            $0.value(forHTTPHeaderField: "Authorization")
        }) == ["Bearer first-account-token", "Bearer second-account-token"])
    }

    @Test func serviceCopiesUseAtMostOneGitHubConnectionAtATime() async {
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, data: Data("[]".utf8), delay: 0.05),
            .init(statusCode: 200, data: Data("[]".utf8), delay: 0.05),
        ])
        let service = PullRequestProbeService()
        let secondWindowService = service

        async let recent = service.performRequest(
            session: makeSession(),
            endpoint: endpoint,
            authHeader: "Bearer test-token"
        )
        async let branch = secondWindowService.performRequest(
            session: makeSession(),
            endpoint: "repos/manaflow-ai/cmux/pulls?head=manaflow-ai:issue-8175",
            authHeader: "Bearer test-token"
        )
        _ = await [recent, branch]

        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 2)
        #expect(GitHubPullRequestStubURLProtocol.maximumConcurrentRequestCount() == 1)
    }
}

import Foundation
import Testing
@testable import CmuxGit

private final class GitHubPullRequestStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
        let delay: TimeInterval
        let gate: String?

        init(
            statusCode: Int,
            headers: [String: String] = [:],
            data: Data = Data(),
            delay: TimeInterval = 0,
            gate: String? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.data = data
            self.delay = delay
            self.gate = gate
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var activeRequestCount = 0
    nonisolated(unsafe) private static var maximumActiveRequestCount = 0
    nonisolated(unsafe) private static var gatedFinishes: [String: @Sendable () -> Void] = [:]

    static func reset(stubs: [Stub]) {
        lock.lock()
        self.stubs = stubs
        requests = []
        activeRequestCount = 0
        maximumActiveRequestCount = 0
        gatedFinishes = [:]
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

    static func releaseGate(_ gate: String) {
        lock.lock()
        let finish = gatedFinishes.removeValue(forKey: gate)
        lock.unlock()
        finish?()
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
        Self.lock.lock()
        if let gate = stub.gate { Self.gatedFinishes[gate] = finish }
        Self.requests.append(request)
        Self.lock.unlock()
        if stub.gate != nil {
            return
        } else if stub.delay > 0 {
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

    private func waitForRequestCount(_ count: Int) async {
        while GitHubPullRequestStubURLProtocol.capturedRequests().count < count {
            await Task.yield()
        }
    }

    @Test func missingCredentialsNeverStartsAnonymousTransport() async {
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, data: Data("[]".utf8)),
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())

        let response = await coordinator.response(
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
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())

        let first = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer test-token"
        )
        let second = await coordinator.response(
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
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())

        _ = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer first-account-token"
        )
        let changedAccountResponse = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer second-account-token"
        )
        let originalAccountResponse = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer first-account-token"
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
        let coordinator = GitHubPullRequestRequestCoordinator(
            session: makeSession(),
            maximumCachedResponseCount: 2
        )

        for endpoint in [firstEndpoint, secondEndpoint, thirdEndpoint] {
            _ = await coordinator.response(
                endpoint: endpoint,
                authHeader: "Bearer test-token"
            )
        }
        let retained = await coordinator.response(
            endpoint: secondEndpoint,
            authHeader: "Bearer test-token"
        )
        _ = await coordinator.response(
            endpoint: firstEndpoint,
            authHeader: "Bearer test-token"
        )

        #expect(retained?.data == secondBody)
        let requests = GitHubPullRequestStubURLProtocol.capturedRequests()
        #expect(requests.count == 5)
        #expect(requests[3].value(forHTTPHeaderField: "If-None-Match") == "\"second\"")
        #expect(requests[4].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func exhaustedRateLimitSuppressesRequestsUntilReset() async {
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
        let coordinator = GitHubPullRequestRequestCoordinator(
            session: makeSession(),
            now: { now }
        )

        _ = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer test-token"
        )
        let suppressed = await coordinator.response(
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
        let coordinator = GitHubPullRequestRequestCoordinator(
            session: makeSession(),
            now: { now }
        )

        _ = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer exhausted-token"
        )
        let changedCredentialResponse = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer available-token"
        )
        let exhaustedCredentialRetryDate = await coordinator.retryDate(
            authHeader: "Bearer exhausted-token"
        )
        let availableCredentialRetryDate = await coordinator.retryDate(
            authHeader: "Bearer available-token"
        )
        let expectedExhaustedRetryDate = Date(
            timeIntervalSince1970: TimeInterval(reset + 1)
        )
        let originalCredentialResponse = await coordinator.response(
            endpoint: "repos/manaflow-ai/cmux/pulls?state=open",
            authHeader: "Bearer exhausted-token"
        )

        #expect(changedCredentialResponse?.statusCode == 200)
        #expect(exhaustedCredentialRetryDate == expectedExhaustedRetryDate)
        #expect(availableCredentialRetryDate == nil)
        #expect(originalCredentialResponse == nil)
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 2)
    }

    @Test func permissionDeniedResponseDoesNotTriggerPrimaryRateLimitBackoff() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = Int(now.addingTimeInterval(300).timeIntervalSince1970)
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
        let coordinator = GitHubPullRequestRequestCoordinator(
            session: makeSession(),
            now: { now }
        )

        _ = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer test-token"
        )
        let subsequent = await coordinator.response(
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
        let coordinator = GitHubPullRequestRequestCoordinator(
            session: makeSession(),
            now: { now }
        )

        _ = await coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer test-token"
        )
        let suppressed = await coordinator.response(
            endpoint: "repos/manaflow-ai/cmux/pulls?state=open",
            authHeader: "Bearer test-token"
        )

        #expect(suppressed == nil)
        #expect(
            await coordinator.retryDate(authHeader: "Bearer test-token")
                == now.addingTimeInterval(120)
        )
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 1)
    }

    @Test func duplicateEndpointRequestsShareOneInFlightTransport() async {
        let body = Data("[]".utf8)
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, data: body, delay: 0.05),
            .init(statusCode: 200, data: body, delay: 0.05),
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())

        async let first = coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer test-token"
        )
        async let second = coordinator.response(
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
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())

        async let first = coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer first-account-token"
        )
        async let second = coordinator.response(
            endpoint: endpoint,
            authHeader: "Bearer second-account-token"
        )
        _ = await [first, second]

        let requests = GitHubPullRequestStubURLProtocol.capturedRequests()
        #expect(requests.count == 2)
        #expect(Set(requests.compactMap {
            $0.value(forHTTPHeaderField: "Authorization")
        }) == ["Bearer first-account-token", "Bearer second-account-token"])
    }

    @Test func coordinatorUsesBoundedConcurrentTransportPool() async {
        let gates = (0..<4).map { "pool-\($0)" }
        GitHubPullRequestStubURLProtocol.reset(stubs: gates.map { .init(statusCode: 200, gate: $0) })
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())
        let tasks = gates.indices.map { index in
            Task { await coordinator.response(endpoint: endpoint + "&page=\(index)", authHeader: "Bearer token") }
        }
        await waitForRequestCount(3)
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 3)
        #expect(GitHubPullRequestStubURLProtocol.maximumConcurrentRequestCount() == 3)
        GitHubPullRequestStubURLProtocol.releaseGate(gates[0])
        await waitForRequestCount(4)
        #expect(GitHubPullRequestStubURLProtocol.maximumConcurrentRequestCount() == 3)
        for gate in gates.dropFirst() { GitHubPullRequestStubURLProtocol.releaseGate(gate) }
        for task in tasks { #expect(await task.value?.statusCode == 200) }
    }

    @Test func cancelingOnlyQueuedWaiterPreventsItsTransport() async {
        let gates = (0..<3).map { "blocker-\($0)" }
        let stubs = gates.map { GitHubPullRequestStubURLProtocol.Stub(statusCode: 200, gate: $0) }
            + [.init(statusCode: 200)]
        GitHubPullRequestStubURLProtocol.reset(stubs: stubs)
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())
        let blockers = gates.indices.map { index in
            Task { await coordinator.response(endpoint: endpoint + "&page=\(index)", authHeader: "Bearer token") }
        }
        await waitForRequestCount(3)
        let queued = Task {
            await coordinator.response(endpoint: endpoint + "&page=queued", authHeader: "Bearer token")
        }
        await Task.yield()
        _ = await coordinator.retryDate(authHeader: "Bearer token")
        queued.cancel()
        await Task.yield()
        _ = await coordinator.retryDate(authHeader: "Bearer token")
        for gate in gates { GitHubPullRequestStubURLProtocol.releaseGate(gate) }
        for blocker in blockers { _ = await blocker.value }
        #expect(await queued.value == nil)
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 3)
    }

    @Test func cancelingOneCoalescedWaiterPreservesTransportForSurvivor() async {
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, data: Data("[]".utf8), gate: "shared"),
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())
        let canceled = Task { await coordinator.response(endpoint: endpoint, authHeader: "Bearer token") }
        await waitForRequestCount(1)
        let survivor = Task { await coordinator.response(endpoint: endpoint, authHeader: "Bearer token") }
        await Task.yield()
        _ = await coordinator.retryDate(authHeader: "Bearer token")
        canceled.cancel()
        GitHubPullRequestStubURLProtocol.releaseGate("shared")

        #expect(await canceled.value == nil)
        #expect(await survivor.value?.statusCode == 200)
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 1)
    }
}

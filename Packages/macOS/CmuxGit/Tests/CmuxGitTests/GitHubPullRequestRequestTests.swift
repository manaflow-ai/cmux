import Foundation
import Testing
@testable import CmuxGit

@Suite(.serialized)
struct GitHubPullRequestRequestTests {
    private let endpoint = "repos/manaflow-ai/cmux/pulls?state=all"

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubPullRequestStubURLProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        return URLSession(configuration: configuration)
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

    @Test func inFlightNotModifiedUsesTheBodyThatSuppliedItsETag() async throws {
        let originalBody = Data("[{\"number\":8175}]".utf8)
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, headers: ["ETag": "\"original\""], data: originalBody),
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(
            session: makeSession(),
            maximumCachedResponseCount: 1
        )
        _ = await coordinator.response(endpoint: endpoint, authHeader: "Bearer test-token")

        let otherEndpoint = "repos/manaflow-ai/cmux/pulls?head=manaflow-ai:other"
        let requestsStarted = GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 304, gate: "revalidate"),
            .init(statusCode: 200, headers: ["ETag": "\"other\""], data: Data("[]".utf8)),
        ])
        let revalidation = Task {
            await coordinator.response(endpoint: endpoint, authHeader: "Bearer test-token")
        }
        #expect(await requestsStarted.wait())

        _ = await coordinator.response(endpoint: otherEndpoint, authHeader: "Bearer test-token")
        GitHubPullRequestStubURLProtocol.releaseGate("revalidate")
        let response = await revalidation.value

        #expect(response?.statusCode == 200)
        #expect(response?.data == originalBody)
        let requests = GitHubPullRequestStubURLProtocol.capturedRequests()
        #expect(requests.count == 2)
        #expect(try #require(requests.first).value(forHTTPHeaderField: "If-None-Match") == "\"original\"")
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
        let requestsStarted = GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, data: body, gate: "shared"),
            .init(statusCode: 200, data: body),
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())
        let first = Task { await coordinator.response(endpoint: endpoint, authHeader: "Bearer test-token") }
        #expect(await requestsStarted.wait())
        let second = Task { await coordinator.response(endpoint: endpoint, authHeader: "Bearer test-token") }
        #expect(await GitHubPullRequestTestSignal.waitUntil {
            let inFlight = await coordinator.inFlightRequestByRequestKey
            return inFlight.values.first?.waiterIDs.count == 2
        })
        GitHubPullRequestStubURLProtocol.releaseGate("shared")
        let responses = await [first.value, second.value]

        #expect(responses.allSatisfy { $0?.statusCode == 200 && $0?.data == body })
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 1)
    }

    @Test func changedCredentialDoesNotJoinInFlightEndpointRequest() async {
        let requestsStarted = GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, gate: "first"),
            .init(statusCode: 200, gate: "second"),
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())
        let first = Task { await coordinator.response(endpoint: endpoint, authHeader: "Bearer first-token") }
        #expect(await requestsStarted.wait())
        let second = Task { await coordinator.response(endpoint: endpoint, authHeader: "Bearer second-token") }
        #expect(await requestsStarted.wait(until: 2))
        GitHubPullRequestStubURLProtocol.releaseGate("first")
        GitHubPullRequestStubURLProtocol.releaseGate("second")
        _ = await [first.value, second.value]

        let requests = GitHubPullRequestStubURLProtocol.capturedRequests()
        #expect(requests.count == 2)
        #expect(Set(requests.compactMap {
            $0.value(forHTTPHeaderField: "Authorization")
        }) == ["Bearer first-token", "Bearer second-token"])
    }

    @Test func coordinatorUsesBoundedConcurrentTransportPool() async {
        let gates = (0..<4).map { "pool-\($0)" }
        let requestsStarted = GitHubPullRequestStubURLProtocol.reset(
            stubs: gates.map { .init(statusCode: 200, gate: $0) }
        )
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())
        let tasks = gates.indices.map { index in
            Task { await coordinator.response(endpoint: endpoint + "&page=\(index)", authHeader: "Bearer token") }
        }
        #expect(await requestsStarted.wait(until: 3))
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 3)
        #expect(GitHubPullRequestStubURLProtocol.maximumConcurrentRequestCount() == 3)
        GitHubPullRequestStubURLProtocol.releaseGate(gates[0])
        #expect(await requestsStarted.wait(until: 4))
        #expect(GitHubPullRequestStubURLProtocol.maximumConcurrentRequestCount() == 3)
        for gate in gates.dropFirst() { GitHubPullRequestStubURLProtocol.releaseGate(gate) }
        for task in tasks { #expect(await task.value?.statusCode == 200) }
    }

    @Test func cancelingOnlyQueuedWaiterPreventsItsTransport() async {
        let gates = (0..<3).map { "blocker-\($0)" }
        let stubs = gates.map { GitHubPullRequestStub(statusCode: 200, gate: $0) }
            + [.init(statusCode: 200)]
        let requestsStarted = GitHubPullRequestStubURLProtocol.reset(stubs: stubs)
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())
        let blockers = gates.indices.map { index in
            Task { await coordinator.response(endpoint: endpoint + "&page=\(index)", authHeader: "Bearer token") }
        }
        #expect(await requestsStarted.wait(until: 3))
        let cancellationFinished = GitHubPullRequestTestSignal()
        let queued = Task {
            let response = await coordinator.response(
                endpoint: endpoint + "&page=queued",
                authHeader: "Bearer token"
            )
            await cancellationFinished.signal()
            return response
        }
        #expect(await GitHubPullRequestTestSignal.waitUntil {
            await coordinator.queuedTransports.count == 1
        })
        queued.cancel()
        #expect(await cancellationFinished.wait())
        for gate in gates { GitHubPullRequestStubURLProtocol.releaseGate(gate) }
        for blocker in blockers { _ = await blocker.value }
        #expect(await queued.value == nil)
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 3)
    }

    @Test func cancelingOneCoalescedWaiterPreservesTransportForSurvivor() async {
        let requestsStarted = GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, data: Data("[]".utf8), gate: "shared"),
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())
        let cancellationFinished = GitHubPullRequestTestSignal()
        let canceled = Task {
            let response = await coordinator.response(endpoint: endpoint, authHeader: "Bearer token")
            await cancellationFinished.signal()
            return response
        }
        #expect(await requestsStarted.wait())
        let survivor = Task { await coordinator.response(endpoint: endpoint, authHeader: "Bearer token") }
        #expect(await GitHubPullRequestTestSignal.waitUntil {
            let inFlight = await coordinator.inFlightRequestByRequestKey
            return inFlight.values.first?.waiterIDs.count == 2
        })
        canceled.cancel()
        #expect(await cancellationFinished.wait(timeout: .milliseconds(500)))
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 1)
        GitHubPullRequestStubURLProtocol.releaseGate("shared")

        #expect(await canceled.value == nil)
        #expect(await survivor.value?.statusCode == 200)
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 1)
    }
}

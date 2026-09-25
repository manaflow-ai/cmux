import Foundation
import Testing
@testable import CmuxGit

extension GitHubPullRequestRequestTests {
    @Test func graphQLBodiesHaveIndependentConditionalCaches() async throws {
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 200, headers: ["ETag": "one"], data: Data("one".utf8)),
            .init(statusCode: 200, data: Data("two".utf8))
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession())
        let first = await coordinator.response(endpoint: "graphql", authHeader: "Bearer fixture", body: Data("query1".utf8))
        let second = await coordinator.response(endpoint: "graphql", authHeader: "Bearer fixture", body: Data("query2".utf8))
        #expect(first?.data == Data("one".utf8))
        #expect(second?.data == Data("two".utf8))
        let requests = GitHubPullRequestStubURLProtocol.capturedRequests()
        #expect(requests.count == 2)
        #expect(requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(requests.last?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test(arguments: [false, true])
    func primaryQuotaIsScopedToItsAPIResource(graphQLFirst: Bool) async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800000300"]),
            .init(statusCode: 200)
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession(), now: { now })
        let first = graphQLFirst ? "graphql" : "repos/o/r/pulls"
        let second = graphQLFirst ? "repos/o/r/pulls" : "graphql"
        _ = await coordinator.response(endpoint: first, authHeader: "Bearer fixture")
        #expect(await coordinator.response(endpoint: first, authHeader: "Bearer fixture") == nil)
        #expect(await coordinator.response(endpoint: second, authHeader: "Bearer fixture")?.statusCode == 200)
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 2)
    }

    @Test(arguments: [false, true])
    func secondaryQuotaStopsBothAPIResources(graphQLFirst: Bool) async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        GitHubPullRequestStubURLProtocol.reset(stubs: [
            .init(statusCode: 429, headers: ["Retry-After": "120"])
        ])
        let coordinator = GitHubPullRequestRequestCoordinator(session: makeSession(), now: { now })
        _ = await coordinator.response(endpoint: graphQLFirst ? "graphql" : "repos/o/r/pulls", authHeader: "Bearer fixture")
        #expect(await coordinator.response(endpoint: "graphql", authHeader: "Bearer fixture") == nil)
        #expect(await coordinator.response(endpoint: "repos/o/r/pulls", authHeader: "Bearer fixture") == nil)
        #expect(await coordinator.retryDate(authHeader: "Bearer fixture", resource: .graphql) == now.addingTimeInterval(120))
        #expect(await coordinator.retryDate(authHeader: "Bearer fixture") == now.addingTimeInterval(120))
        #expect(GitHubPullRequestStubURLProtocol.capturedRequests().count == 1)
    }

}

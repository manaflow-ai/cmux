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

}

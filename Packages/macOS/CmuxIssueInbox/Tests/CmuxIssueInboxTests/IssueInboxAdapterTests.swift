@testable import CmuxIssueInbox
import Foundation
import Testing

@Suite
struct IssueInboxAdapterTests {
    @Test
    func githubAdapterNormalizesIssuesAndFiltersPullRequests() async throws {
        let data = Data("""
        [
          {
            "number": 123,
            "state": "open",
            "html_url": "https://github.com/manaflow-ai/cmux/issues/123",
            "title": "Add inbox",
            "updated_at": "2026-07-01T12:34:56Z",
            "assignees": [{"login": "alice"}],
            "labels": [{"name": "feature"}, {"name": "macOS"}]
          },
          {
            "number": 124,
            "state": "open",
            "html_url": "https://github.com/manaflow-ai/cmux/pull/124",
            "title": "A pull request",
            "updated_at": "2026-07-01T12:35:56Z",
            "assignees": [],
            "labels": [],
            "pull_request": {"url": "https://api.github.com/repos/manaflow-ai/cmux/pulls/124"}
          }
        ]
        """.utf8)
        let transport = FixtureTransport { request in
            #expect(request.url?.absoluteString == "https://api.github.com/repos/manaflow-ai/cmux/issues?state=open&per_page=100")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            return (data, FixtureTransport.response(statusCode: 200, url: request.url))
        }
        let adapter = try GitHubIssueSourceAdapter(
            config: IssueInboxSourceConfig(type: .github, repo: "manaflow-ai/cmux"),
            transport: transport,
            environment: ["GH_TOKEN": "test-token"]
        )

        let items = try await adapter.fetchIssues()

        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.id == "github:manaflow-ai/cmux:123")
        #expect(item.provider == .github)
        #expect(item.status == .open)
        #expect(item.repoOrProject == "manaflow-ai/cmux")
        #expect(item.number == "123")
        #expect(item.assignees == ["alice"])
        #expect(item.labels == ["feature", "macOS"])
    }

    @Test
    func githubAdapterTreatsEmptyGHTokenAsUnset() async throws {
        let transport = FixtureTransport { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fallback-token")
            return (Data("[]".utf8), FixtureTransport.response(statusCode: 200, url: request.url))
        }
        let adapter = try GitHubIssueSourceAdapter(
            config: IssueInboxSourceConfig(type: .github, repo: "manaflow-ai/cmux"),
            transport: transport,
            environment: [
                "GH_TOKEN": "  ",
                "GITHUB_TOKEN": "fallback-token",
            ]
        )

        let items = try await adapter.fetchIssues()

        #expect(items.isEmpty)
    }

    @Test
    func linearAdapterNormalizesIssuesAndMapsWorkflowState() async throws {
        let data = Data("""
        {
          "data": {
            "issues": {
              "nodes": [
                {
                  "identifier": "ENG-42",
                  "title": "Fix spawn",
                  "url": "https://linear.app/cmux/issue/ENG-42/fix-spawn",
                  "updatedAt": "2026-07-02T10:00:00.000Z",
                  "state": {"name": "Done", "type": "completed"},
                  "assignee": {"name": "Rina"},
                  "labels": {"nodes": [{"name": "bug"}]}
                },
                {
                  "identifier": "ENG-43",
                  "title": "Build inbox",
                  "url": "https://linear.app/cmux/issue/ENG-43/build-inbox",
                  "updatedAt": "2026-07-03T10:00:00.000Z",
                  "state": {"name": "In Progress", "type": "started"},
                  "assignee": null,
                  "labels": {"nodes": [{"name": "feature"}]}
                }
              ]
            }
          }
        }
        """.utf8)
        let transport = FixtureTransport { request in
            #expect(request.url?.absoluteString == "https://api.linear.app/graphql")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "linear-token")
            return (data, FixtureTransport.response(statusCode: 200, url: request.url))
        }
        let adapter = try LinearIssueSourceAdapter(
            config: IssueInboxSourceConfig(type: .linear, teamKey: "ENG"),
            transport: transport,
            environment: ["LINEAR_API_KEY": "linear-token"]
        )

        let items = try await adapter.fetchIssues()

        #expect(items.map(\.id) == ["linear:ENG:ENG-43", "linear:ENG:ENG-42"])
        #expect(items[0].status == .open)
        #expect(items[0].providerState == "started")
        #expect(items[1].status == .closed)
        #expect(items[1].providerState == "completed")
        #expect(items[1].assignees == ["Rina"])
        #expect(items[1].labels == ["bug"])
    }

    @Test
    func linearAdapterThrowsMissingCredentials() async throws {
        let adapter = try LinearIssueSourceAdapter(
            config: IssueInboxSourceConfig(type: .linear, teamKey: "ENG"),
            transport: FixtureTransport { request in
                Issue.record("Unexpected request \(String(describing: request.url))")
                return (Data(), FixtureTransport.response(statusCode: 200, url: request.url))
            },
            environment: [:]
        )

        await #expect(throws: IssueSourceError.missingCredentials(provider: .linear, envVar: "LINEAR_API_KEY")) {
            _ = try await adapter.fetchIssues()
        }
    }
}

private struct FixtureTransport: IssueInboxHTTPTransport {
    var handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await handler(request)
    }

    static func response(statusCode: Int, url: URL?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

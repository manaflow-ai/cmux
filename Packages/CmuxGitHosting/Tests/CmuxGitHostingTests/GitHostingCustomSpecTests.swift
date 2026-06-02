import Testing
@testable import CmuxGitHosting
import Foundation

/// Exercises the fully customizable path: a host cmux has never heard of, described
/// entirely in `cmux.json`, with no built-in preset involved.
@Suite struct GitHostingCustomSpecTests {
    private static let configJSON = """
    {
      "providers": [
        {
          "host": "git.internal",
          "spec": {
            "apiBaseURL": "https://{host}/api/v1/",
            "pullRequestsPath": "repos/{path}/pulls",
            "query": [{"name": "state", "value": "all"}],
            "branchFilter": {"name": "head", "valueTemplate": "{branch}"},
            "auth": {"scheme": "token", "token": {"environment": ["GITEA_TOKEN"]}},
            "response": {
              "number": "number",
              "url": "html_url",
              "state": "state",
              "mergedWhenPresent": "merged_at",
              "headRef": "head.ref",
              "baseRef": "base.ref",
              "stateMap": {"OPEN": "OPEN", "CLOSED": "CLOSED"}
            }
          }
        }
      ]
    }
    """

    private func decodedConfig() throws -> GitHostingConfig {
        let data = try #require(Self.configJSON.data(using: .utf8))
        return try JSONDecoder().decode(GitHostingConfig.self, from: data)
    }

    @Test func decodesCustomProviderFromJSON() throws {
        let config = try decodedConfig()
        #expect(config.rules.count == 1)
        let rule = try #require(config.rule(matchingHost: "git.internal"))
        let spec = try #require(rule.resolvedSpec())
        #expect(spec.apiBaseURL == "https://{host}/api/v1/")
        #expect(spec.auth.scheme == "token")
    }

    @Test func buildsRequestAndParsesResponseForCustomHost() async throws {
        let resolver = GitHostingResolver(
            config: try decodedConfig(),
            environment: ["GITEA_TOKEN": "gt"],
            commandRunner: RecordingCommandRunner(),
            workingDirectory: "/tmp"
        )
        let plan = try #require(await resolver.resolvePlan(forHost: "git.internal"))
        #expect(plan.token == "gt")

        let ref = try #require(GitRemoteReference.parse(remoteURL: "git@git.internal:team/app.git"))
        let request = try #require(plan.repositoryRequest(for: ref, page: 1))
        let url = try #require(request.url)
        #expect(url.host == "git.internal")
        #expect(url.path == "/api/v1/repos/team/app/pulls")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "token gt")

        let json = """
        [{"number":12,"state":"closed","html_url":"https://git.internal/team/app/pulls/12",
          "merged_at":"2024-05-01T00:00:00Z","head":{"ref":"feat"},"base":{"ref":"main"}}]
        """
        let jsonData = try #require(json.data(using: .utf8))
        let prs = try #require(plan.parsePullRequests(from: jsonData))
        #expect(prs.count == 1)
        #expect(prs[0].number == 12)
        #expect(prs[0].state == .merged)
        #expect(prs[0].headRefName == "feat")
    }

    @Test func emptyConfigRoundTripsToDefault() throws {
        let data = try #require("{}".data(using: .utf8))
        let config = try JSONDecoder().decode(GitHostingConfig.self, from: data)
        #expect(config == .default)
        #expect(config.autoDetect)
        #expect(config.autoDiscoverGitHubEnterprise)
    }
}

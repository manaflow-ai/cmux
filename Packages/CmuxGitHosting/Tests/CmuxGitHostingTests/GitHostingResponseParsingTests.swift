import Testing
@testable import CmuxGitHosting
import Foundation

@Suite struct GitHostingResponseParsingTests {
    private func parse(_ preset: GitHostingPreset, _ json: String) throws -> [HostedPullRequest] {
        let plan = GitHostingRequestPlan(spec: preset.spec, apiHost: "example.com", token: nil)
        let data = try #require(json.data(using: .utf8))
        return try #require(plan.parsePullRequests(from: data))
    }

    @Test func parsesGitHubStatesIncludingMergedViaMergedAt() throws {
        let json = """
        [
          {"number":7,"state":"open","html_url":"https://github.com/o/r/pull/7",
           "updated_at":"2024-01-02T00:00:00Z","merged_at":null,"head":{"ref":"feat"},"base":{"ref":"main"}},
          {"number":8,"state":"closed","html_url":"https://github.com/o/r/pull/8",
           "updated_at":"2024-01-03T00:00:00Z","merged_at":"2024-01-03T01:00:00Z","head":{"ref":"done"},"base":{"ref":"main"}},
          {"number":9,"state":"closed","html_url":"https://github.com/o/r/pull/9",
           "updated_at":"2024-01-04T00:00:00Z","merged_at":null,"head":{"ref":"gone"},"base":{"ref":"main"}}
        ]
        """
        let prs = try parse(.github, json)
        #expect(prs.count == 3)
        #expect(prs[0] == HostedPullRequest(
            number: 7, state: .open, url: "https://github.com/o/r/pull/7",
            updatedAt: "2024-01-02T00:00:00Z", mergedAt: nil, headRefName: "feat", baseRefName: "main"
        ))
        #expect(prs[1].state == .merged)
        #expect(prs[1].mergedAt == "2024-01-03T01:00:00Z")
        #expect(prs[2].state == .closed)
    }

    @Test func parsesGitLabStates() throws {
        let json = """
        [
          {"iid":3,"state":"opened","web_url":"https://gitlab.com/g/a/-/merge_requests/3","updated_at":"t","source_branch":"feat","target_branch":"main"},
          {"iid":4,"state":"merged","web_url":"u4","updated_at":"t","source_branch":"b4","target_branch":"main"},
          {"iid":5,"state":"locked","web_url":"u5","updated_at":"t","source_branch":"b5","target_branch":"main"},
          {"iid":6,"state":"closed","web_url":"u6","updated_at":"t","source_branch":"b6","target_branch":"main"}
        ]
        """
        let prs = try parse(.gitlab, json)
        #expect(prs.map(\.number) == [3, 4, 5, 6])
        #expect(prs.map(\.state) == [.open, .merged, .open, .closed])
        #expect(prs[0].url == "https://gitlab.com/g/a/-/merge_requests/3")
        #expect(prs[0].headRefName == "feat")
    }

    @Test func parsesBitbucketNestedFieldsAndStates() throws {
        let json = """
        {"values":[
          {"id":5,"state":"OPEN","links":{"html":{"href":"https://bitbucket.org/w/r/pull-requests/5"}},
           "updated_on":"t","source":{"branch":{"name":"feat"}},"destination":{"branch":{"name":"main"}}},
          {"id":6,"state":"MERGED","links":{"html":{"href":"u6"}},"updated_on":"t","source":{"branch":{"name":"b6"}},"destination":{"branch":{"name":"main"}}},
          {"id":7,"state":"DECLINED","links":{"html":{"href":"u7"}},"updated_on":"t","source":{"branch":{"name":"b7"}},"destination":{"branch":{"name":"main"}}},
          {"id":8,"state":"SUPERSEDED","links":{"html":{"href":"u8"}},"updated_on":"t","source":{"branch":{"name":"b8"}},"destination":{"branch":{"name":"main"}}}
        ]}
        """
        let prs = try parse(.bitbucketCloud, json)
        #expect(prs.map(\.number) == [5, 6, 7, 8])
        #expect(prs.map(\.state) == [.open, .merged, .closed, .closed])
        #expect(prs[0].url == "https://bitbucket.org/w/r/pull-requests/5")
        #expect(prs[0].headRefName == "feat")
        #expect(prs[0].baseRefName == "main")
    }

    @Test func dropsRequestsWithUnknownState() throws {
        // "draft" is not in GitHub's state map and there is no merged_at → dropped.
        let json = """
        [{"number":1,"state":"draft","html_url":"u","head":{"ref":"x"}}]
        """
        #expect(try parse(.github, json).isEmpty)
    }

    @Test func returnsNilForNonListBody() throws {
        let plan = GitHostingRequestPlan(spec: GitHostingPreset.github.spec, apiHost: "github.com", token: nil)
        let data = try #require(#"{"message":"Not Found"}"#.data(using: .utf8))
        #expect(plan.parsePullRequests(from: data) == nil)
    }
}

import Testing
@testable import CmuxGitHosting
import Foundation

@Suite struct GitHostingRequestTests {
    private func reference(_ remote: String) throws -> GitRemoteReference {
        try #require(GitRemoteReference.parse(remoteURL: remote))
    }

    // MARK: GitHub (regression: must match the original hardcoded poller)

    @Test func githubRepositoryRequestMatchesLegacyShape() throws {
        let plan = GitHostingRequestPlan(spec: GitHostingPreset.github.spec, apiHost: "github.com", token: "tok123")
        let ref = try reference("git@github.com:manaflow-ai/cmux.git")
        let request = try #require(plan.repositoryRequest(for: ref, page: 1))
        let url = try #require(request.url)

        #expect(url.host == "api.github.com")
        #expect(url.path == "/repos/manaflow-ai/cmux/pulls")
        #expect(queryPairs(of: request) == [
            "state=all", "sort=updated", "direction=desc", "per_page=100", "page=1",
        ])
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "cmux-workspace-pr-poller")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok123")
    }

    @Test func githubBranchRequestFiltersByHeadWithoutPage() throws {
        let plan = GitHostingRequestPlan(spec: GitHostingPreset.github.spec, apiHost: "github.com", token: nil)
        let ref = try reference("git@github.com:manaflow-ai/cmux.git")
        let request = try #require(plan.branchRequest(for: ref, branch: "feature/x"))

        let pairs = queryPairs(of: request)
        #expect(pairs.contains("head=manaflow-ai:feature/x"))
        #expect(pairs.contains("per_page=100"))
        #expect(!pairs.contains { $0.hasPrefix("page=") })
        // Anonymous: no Authorization header.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func githubEnterpriseTargetsApiV3OnTheHost() throws {
        var spec = GitHostingPreset.github.spec
        spec.apiBaseURL = "https://{host}/api/v3/"
        let plan = GitHostingRequestPlan(spec: spec, apiHost: "ghe.example.com", token: "ent")
        let ref = try reference("git@ghe.example.com:team/app.git")
        let url = try #require(plan.repositoryRequest(for: ref, page: 1)?.url)

        #expect(url.host == "ghe.example.com")
        #expect(url.path == "/api/v3/repos/team/app/pulls")
    }

    // MARK: GitLab

    @Test func gitlabRequestUrlEncodesProjectPath() throws {
        let plan = GitHostingRequestPlan(spec: GitHostingPreset.gitlab.spec, apiHost: "gitlab.com", token: "glt")
        let ref = try reference("git@gitlab.com:group/subgroup/app.git")
        let request = try #require(plan.repositoryRequest(for: ref, page: 1))
        let url = try #require(request.url)

        #expect(url.host == "gitlab.com")
        #expect(url.absoluteString.contains("/api/v4/projects/group%2Fsubgroup%2Fapp/merge_requests"))
        let pairs = queryPairs(of: request)
        #expect(pairs.contains("state=all"))
        #expect(pairs.contains("order_by=updated_at"))
        #expect(pairs.contains("sort=desc"))
        #expect(pairs.contains("per_page=100"))
    }

    @Test func gitlabBranchRequestUsesSourceBranch() throws {
        let plan = GitHostingRequestPlan(spec: GitHostingPreset.gitlab.spec, apiHost: "gitlab.com", token: "glt")
        let ref = try reference("git@gitlab.com:group/app.git")
        let request = try #require(plan.branchRequest(for: ref, branch: "feat"))
        #expect(queryPairs(of: request).contains("source_branch=feat"))
    }

    // MARK: Bitbucket

    @Test func bitbucketRequestTargetsApiHostWithAllStates() throws {
        let plan = GitHostingRequestPlan(spec: GitHostingPreset.bitbucketCloud.spec, apiHost: "bitbucket.org", token: "bbt")
        let ref = try reference("https://bitbucket.org/workspace/repo.git")
        let request = try #require(plan.repositoryRequest(for: ref, page: 1))
        let url = try #require(request.url)

        #expect(url.host == "api.bitbucket.org")
        #expect(url.path == "/2.0/repositories/workspace/repo/pullrequests")
        let pairs = queryPairs(of: request)
        #expect(pairs.contains("state=OPEN"))
        #expect(pairs.contains("state=MERGED"))
        #expect(pairs.contains("state=DECLINED"))
        #expect(pairs.contains("state=SUPERSEDED"))
        #expect(pairs.contains("pagelen=50"))
    }

    @Test func bitbucketBranchRequestUsesQFilter() throws {
        let plan = GitHostingRequestPlan(spec: GitHostingPreset.bitbucketCloud.spec, apiHost: "bitbucket.org", token: "bbt")
        let ref = try reference("https://bitbucket.org/workspace/repo.git")
        let request = try #require(plan.branchRequest(for: ref, branch: "feat"))
        #expect(queryPairs(of: request).contains(#"q=source.branch.name="feat""#))
    }
}

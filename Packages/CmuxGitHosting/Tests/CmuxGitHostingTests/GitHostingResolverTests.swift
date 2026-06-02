import Testing
@testable import CmuxGitHosting
import CmuxProcess
import Foundation

@Suite struct GitHostingResolverTests {
    private func resolver(
        config: GitHostingConfig = .default,
        environment: [String: String] = [:],
        runner: RecordingCommandRunner = RecordingCommandRunner()
    ) -> GitHostingResolver {
        GitHostingResolver(
            config: config,
            environment: environment,
            commandRunner: runner,
            workingDirectory: "/tmp"
        )
    }

    @Test func githubPrefersEnvTokenOverCli() async throws {
        let runner = RecordingCommandRunner(outputs: ["gh auth token": "from-cli"])
        let plan = try #require(await resolver(environment: ["GH_TOKEN": "from-env"], runner: runner)
            .resolvePlan(forHost: "github.com"))
        #expect(plan.token == "from-env")
        #expect(await runner.invocations.isEmpty)
    }

    @Test func githubFallsBackToGhCli() async throws {
        let runner = RecordingCommandRunner(outputs: ["gh auth token": "cli-token\n"])
        let plan = try #require(await resolver(runner: runner).resolvePlan(forHost: "github.com"))
        #expect(plan.token == "cli-token")
    }

    @Test func githubRemainsPollableAnonymously() async throws {
        let plan = try #require(await resolver().resolvePlan(forHost: "github.com"))
        #expect(plan.token == nil)
        #expect(plan.spec.apiBaseURL == "https://api.github.com/")
    }

    @Test func gitlabRequiresATokenToPoll() async throws {
        #expect(await resolver().resolvePlan(forHost: "gitlab.com") == nil)

        let plan = try #require(await resolver(environment: ["GITLAB_TOKEN": "glt"])
            .resolvePlan(forHost: "gitlab.com"))
        #expect(plan.token == "glt")
    }

    @Test func discoversEnterpriseGitHubViaGh() async throws {
        let runner = RecordingCommandRunner(
            outputs: ["gh auth token --hostname ghe.example.com": "ent-token"]
        )
        let plan = try #require(await resolver(runner: runner).resolvePlan(forHost: "ghe.example.com"))
        #expect(plan.token == "ent-token")
        #expect(plan.spec.apiBaseURL == "https://{host}/api/v3/")

        let ref = try #require(GitRemoteReference.parse(remoteURL: "git@ghe.example.com:team/app.git"))
        let url = try #require(plan.repositoryRequest(for: ref, page: 1)?.url)
        #expect(url.host == "ghe.example.com")
        #expect(url.path == "/api/v3/repos/team/app/pulls")
    }

    @Test func unknownHostWithoutGhTokenIsNotPollable() async throws {
        #expect(await resolver().resolvePlan(forHost: "git.sr.ht") == nil)
    }

    @Test func autoDiscoveryCanBeDisabled() async throws {
        let runner = RecordingCommandRunner(
            outputs: ["gh auth token --hostname ghe.example.com": "ent-token"]
        )
        let config = GitHostingConfig(autoDiscoverGitHubEnterprise: false)
        #expect(await resolver(config: config, runner: runner).resolvePlan(forHost: "ghe.example.com") == nil)
    }

    @Test func userRuleConfiguresSelfHostedGitLab() async throws {
        let config = GitHostingConfig(rules: [
            GitHostingProviderRule(
                host: "gitlab.internal",
                preset: "gitlab",
                apiBaseURL: "https://gitlab.internal/api/v4/",
                token: GitHostingTokenSource(environment: ["INTERNAL_GL_TOKEN"])
            ),
        ])
        let plan = try #require(await resolver(config: config, environment: ["INTERNAL_GL_TOKEN": "x"])
            .resolvePlan(forHost: "gitlab.internal"))
        #expect(plan.token == "x")

        let ref = try #require(GitRemoteReference.parse(remoteURL: "git@gitlab.internal:team/app.git"))
        let url = try #require(plan.repositoryRequest(for: ref, page: 1)?.url)
        #expect(url.host == "gitlab.internal")
        #expect(url.absoluteString.contains("/api/v4/projects/team%2Fapp/merge_requests"))
    }

    @Test func userRuleWildcardMatchesSubdomains() async throws {
        let config = GitHostingConfig(rules: [
            GitHostingProviderRule(
                host: "*.corp.example",
                preset: "github",
                apiBaseURL: "https://{host}/api/v3/",
                token: GitHostingTokenSource(environment: ["CORP_TOKEN"])
            ),
        ])
        let plan = try #require(await resolver(config: config, environment: ["CORP_TOKEN": "t"])
            .resolvePlan(forHost: "git.corp.example"))
        let ref = try #require(GitRemoteReference.parse(remoteURL: "git@git.corp.example:team/app.git"))
        let url = try #require(plan.repositoryRequest(for: ref, page: 1)?.url)
        #expect(url.host == "git.corp.example")
        #expect(url.path == "/api/v3/repos/team/app/pulls")
    }
}

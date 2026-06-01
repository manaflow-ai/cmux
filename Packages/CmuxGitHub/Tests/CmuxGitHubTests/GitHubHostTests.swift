import Foundation
import Testing
@testable import CmuxGitHub

/// Coverage for issue #5080: a GitHub poller must work against any GitHub-family
/// host `gh` is authenticated to (github.com plus any GitHub Enterprise Server
/// host), not only github.com.
@Suite struct GitHubHostTests {
    // MARK: Remote URL parsing

    @Test func parsesGitHubDotComSSHRemote() {
        let reference = GitHubRepositoryReference.parse(remoteURL: "git@github.com:manaflow-ai/cmux.git")
        #expect(reference?.host == .dotCom)
        #expect(reference?.owner == "manaflow-ai")
        #expect(reference?.repo == "cmux")
        #expect(reference?.slug == "manaflow-ai/cmux")
    }

    @Test func parsesGitHubDotComHTTPSRemote() {
        let reference = GitHubRepositoryReference.parse(remoteURL: "https://github.com/manaflow-ai/cmux.git")
        #expect(reference?.host == .dotCom)
        #expect(reference?.slug == "manaflow-ai/cmux")
    }

    @Test func parsesEnterpriseSSHRemoteWithoutDroppingHost() {
        let reference = GitHubRepositoryReference.parse(remoteURL: "git@ghe.example.com:acme/widgets.git")
        #expect(reference?.host == GitHubHost(hostname: "ghe.example.com"))
        #expect(reference?.owner == "acme")
        #expect(reference?.repo == "widgets")
    }

    @Test func parsesEnterpriseHTTPSRemoteWithoutDroppingHost() {
        let reference = GitHubRepositoryReference.parse(remoteURL: "https://ghe.example.com/acme/widgets")
        #expect(reference?.host == GitHubHost(hostname: "ghe.example.com"))
        #expect(reference?.slug == "acme/widgets")
    }

    @Test func preservesExplicitPortFromEnterpriseHTTPSRemote() {
        // A GHES instance served on a non-default port must keep that port so
        // the REST API base targets it instead of silently falling back to 443.
        let reference = GitHubRepositoryReference.parse(remoteURL: "https://ghe.example.com:8443/acme/widgets.git")
        #expect(reference?.host == GitHubHost(hostname: "ghe.example.com", port: 8443))
        #expect(reference?.host.apiBaseURL?.absoluteString == "https://ghe.example.com:8443/api/v3/")
        // A distinct port is a distinct host identity.
        #expect(reference?.host != GitHubHost(hostname: "ghe.example.com"))
    }

    @Test func parsesEnterpriseSSHSchemeRemoteWithCustomUser() {
        let reference = GitHubRepositoryReference.parse(remoteURL: "ssh://org-1@ghe.example.com/acme/widgets.git/")
        #expect(reference?.host == GitHubHost(hostname: "ghe.example.com"))
        #expect(reference?.slug == "acme/widgets")
    }

    @Test func ignoresSSHTransportPortForAPIBase() {
        // An ssh:// port is the SSH transport port, not the HTTPS REST API port,
        // so it must not end up in the API base URL.
        let reference = GitHubRepositoryReference.parse(remoteURL: "ssh://git@ghe.example.com:2222/acme/widgets.git")
        #expect(reference?.host == GitHubHost(hostname: "ghe.example.com"))
        #expect(reference?.host.apiBaseURL?.absoluteString == "https://ghe.example.com/api/v3/")
    }

    @Test func normalizesExplicitDefaultHTTPSPortToDotCom() {
        // github.com:443 is still the public host; it must keep the GH_TOKEN /
        // anonymous github.com path rather than targeting api on :443.
        let reference = GitHubRepositoryReference.parse(remoteURL: "https://github.com:443/manaflow-ai/cmux.git")
        #expect(reference?.host == .dotCom)
        #expect(reference?.host.isDotCom == true)
        #expect(reference?.host.apiBaseURL?.absoluteString == "https://api.github.com/")
    }

    @Test func normalizesExplicitDefaultHTTPPortToDotCom() {
        let reference = GitHubRepositoryReference.parse(remoteURL: "http://github.com:80/manaflow-ai/cmux.git")
        #expect(reference?.host == .dotCom)
        #expect(reference?.host.isDotCom == true)
    }

    @Test func githubDotComWithProxyPortStillUsesPublicAPI() {
        // github.com's REST API is always api.github.com regardless of the clone
        // port (e.g. behind a proxy on :8080), so it stays anonymous-pollable.
        let reference = GitHubRepositoryReference.parse(remoteURL: "http://github.com:8080/manaflow-ai/cmux.git")
        #expect(reference?.host.isDotCom == true)
        #expect(reference?.host.apiBaseURL?.absoluteString == "https://api.github.com/")
        #expect(reference?.host.isPollable(token: nil) == true)
    }

    @Test func parsesSCPRemoteWithBracketedIPv6Host() {
        // The host/path separator must be found after the bracketed address,
        // not at the first ':' inside the IPv6 literal — and the API base must
        // re-bracket the literal rather than failing to build.
        let reference = GitHubRepositoryReference.parse(remoteURL: "git@[::1]:acme/widgets.git")
        #expect(reference?.host == GitHubHost(hostname: "::1"))
        #expect(reference?.slug == "acme/widgets")
        #expect(reference?.host.apiBaseURL?.absoluteString == "https://[::1]/api/v3/")
    }

    @Test func parsesNonGitHubHostVerbatim() {
        // Parsing is host-agnostic; gitlab.com is preserved and only gated out
        // later by token availability (see pollability tests below).
        let reference = GitHubRepositoryReference.parse(remoteURL: "https://gitlab.com/group/project.git")
        #expect(reference?.host == GitHubHost(hostname: "gitlab.com"))
        #expect(reference?.slug == "group/project")
    }

    @Test func rejectsRemoteWithoutOwnerRepo() {
        #expect(GitHubRepositoryReference.parse(remoteURL: "https://github.com/manaflow-ai") == nil)
        #expect(GitHubRepositoryReference.parse(remoteURL: "") == nil)
    }

    @Test func parsesWebURL() {
        let reference = GitHubRepositoryReference.parse(
            webURL: URL(string: "https://ghe.example.com/acme/widgets/pull/12")!
        )
        #expect(reference?.host == GitHubHost(hostname: "ghe.example.com"))
        #expect(reference?.slug == "acme/widgets")
    }

    // MARK: REST API base URL

    @Test func dotComUsesPublicAPIBase() {
        #expect(GitHubHost.dotCom.apiBaseURL?.absoluteString == "https://api.github.com/")
    }

    @Test func enterpriseUsesPerHostAPIV3Base() {
        #expect(
            GitHubHost(hostname: "ghe.example.com").apiBaseURL?.absoluteString
                == "https://ghe.example.com/api/v3/"
        )
    }

    @Test func apiURLAppendsEndpointRelativeToBase() {
        let dotCom = GitHubHost.dotCom.apiURL(endpoint: "repos/acme/widgets/pulls?state=all")
        #expect(dotCom?.absoluteString == "https://api.github.com/repos/acme/widgets/pulls?state=all")
        let enterprise = GitHubHost(hostname: "ghe.example.com")
            .apiURL(endpoint: "repos/acme/widgets/pulls?state=all")
        #expect(enterprise?.absoluteString == "https://ghe.example.com/api/v3/repos/acme/widgets/pulls?state=all")
    }

    // MARK: Auth token lookup

    @Test func authTokenLookupPassesHostnameToGh() async {
        let captured = TokenRunnerProbe()
        let runner: GitHubHost.TokenCommandRunner = { _, arguments in
            await captured.record(arguments)
            return "ghs_enterprise\n"
        }
        let token = await GitHubHost(hostname: "ghe.example.com").authToken(using: runner)
        #expect(token == "ghs_enterprise")
        #expect(await captured.arguments == ["auth", "token", "--hostname", "ghe.example.com"])
    }

    @Test func authTokenLookupTrimsAndTreatsEmptyAsAbsent() async {
        let blank: GitHubHost.TokenCommandRunner = { _, _ in "   \n" }
        #expect(await GitHubHost(hostname: "ghe.example.com").authToken(using: blank) == nil)
        let missing: GitHubHost.TokenCommandRunner = { _, _ in nil }
        #expect(await GitHubHost(hostname: "ghe.example.com").authToken(using: missing) == nil)
    }

    // MARK: Pollability gating

    @Test func dotComIsPollableWithoutToken() {
        #expect(GitHubHost.dotCom.isPollable(token: nil))
    }

    @Test func enterpriseRequiresTokenToPoll() {
        let host = GitHubHost(hostname: "ghe.example.com")
        #expect(host.isPollable(token: "ghs_enterprise"))
        #expect(!host.isPollable(token: nil))
        #expect(!host.isPollable(token: ""))
    }

    @Test func nonGitHubHostIsNotPollableWithoutToken() {
        #expect(!GitHubHost(hostname: "gitlab.com").isPollable(token: nil))
        #expect(!GitHubHost(hostname: "bitbucket.org").isPollable(token: nil))
    }
}

/// Records the arguments passed to a ``GitHubHost/TokenCommandRunner`` so a test
/// can assert that the GitHub CLI was invoked with `--hostname`.
private actor TokenRunnerProbe {
    private(set) var arguments: [String] = []

    func record(_ arguments: [String]) {
        self.arguments = arguments
    }
}

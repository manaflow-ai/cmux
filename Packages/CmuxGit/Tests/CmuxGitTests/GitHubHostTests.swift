import Foundation
import Testing
@testable import CmuxGit

/// Regression coverage for issue #5080: sidebar PR polling must preserve the
/// remote host and route GitHub Enterprise Server requests to that host.
@Suite struct GitHubHostTests {
    @Test func parsesGitHubDotComSSHRemote() {
        let reference = GitHubRepositoryReference.parse(remoteURL: "git@github.com:manaflow-ai/cmux.git")

        #expect(reference?.host == .dotCom)
        #expect(reference?.owner == "manaflow-ai")
        #expect(reference?.repo == "cmux")
        #expect(reference?.slug == "manaflow-ai/cmux")
    }

    @Test func parsesEnterpriseRemotesWithoutDroppingHost() {
        let ssh = GitHubRepositoryReference.parse(remoteURL: "git@ghe.example.com:acme/widgets.git")
        let https = GitHubRepositoryReference.parse(remoteURL: "https://ghe.example.com/acme/widgets")

        #expect(ssh?.host == GitHubHost(hostname: "ghe.example.com"))
        #expect(ssh?.slug == "acme/widgets")
        #expect(https?.host == GitHubHost(hostname: "ghe.example.com"))
        #expect(https?.slug == "acme/widgets")
    }

    @Test func preservesExplicitEnterpriseHTTPSPort() {
        let reference = GitHubRepositoryReference.parse(remoteURL: "https://ghe.example.com:8443/acme/widgets.git")

        #expect(reference?.host == GitHubHost(hostname: "ghe.example.com", port: 8443))
        #expect(reference?.host.apiBaseURL?.absoluteString == "https://ghe.example.com:8443/api/v3/")
    }

    @Test func ignoresSSHTransportPortForAPIBase() {
        let reference = GitHubRepositoryReference.parse(remoteURL: "ssh://git@ghe.example.com:2222/acme/widgets.git")

        #expect(reference?.host == GitHubHost(hostname: "ghe.example.com"))
        #expect(reference?.host.apiBaseURL?.absoluteString == "https://ghe.example.com/api/v3/")
    }

    @Test func githubDotComUsesPublicAPIRegardlessOfClonePort() {
        let reference = GitHubRepositoryReference.parse(remoteURL: "http://github.com:8080/manaflow-ai/cmux.git")

        #expect(reference?.host.isDotCom == true)
        #expect(reference?.host.apiBaseURL?.absoluteString == "https://api.github.com/")
        #expect(reference?.host.isPollable(token: nil) == true)
    }

    @Test func parsesSCPRemoteWithBracketedIPv6Host() {
        let reference = GitHubRepositoryReference.parse(remoteURL: "git@[::1]:acme/widgets.git")

        #expect(reference?.host == GitHubHost(hostname: "::1"))
        #expect(reference?.slug == "acme/widgets")
        #expect(reference?.host.apiBaseURL?.absoluteString == "https://[::1]/api/v3/")
    }

    @Test func parsesNonGitHubHostVerbatim() {
        let reference = GitHubRepositoryReference.parse(remoteURL: "https://gitlab.com/group/project.git")

        #expect(reference?.host == GitHubHost(hostname: "gitlab.com"))
        #expect(reference?.slug == "group/project")
    }

    @Test func rejectsRemoteWithoutOwnerRepo() {
        #expect(GitHubRepositoryReference.parse(remoteURL: "https://github.com/manaflow-ai") == nil)
        #expect(GitHubRepositoryReference.parse(remoteURL: "") == nil)
    }

    @Test func parsesWebURL() throws {
        let webURL = try #require(URL(string: "https://ghe.example.com/acme/widgets/pull/12"))
        let reference = GitHubRepositoryReference.parse(webURL: webURL)

        #expect(reference?.host == GitHubHost(hostname: "ghe.example.com"))
        #expect(reference?.slug == "acme/widgets")
    }

    @Test func authorityMatchesAPIOriginAcrossPortsAndIPv6() {
        #expect(GitHubHost(hostname: "ghe.example.com").authority == "ghe.example.com")
        #expect(GitHubHost(hostname: "ghe.example.com", port: 8443).authority == "ghe.example.com:8443")
        #expect(GitHubHost(hostname: "::1").authority == "[::1]")
        #expect(GitHubHost(hostname: "::1", port: 8443).authority == "[::1]:8443")
        // Default ports normalize away, so the authority stays portless.
        #expect(GitHubHost(hostname: "ghe.example.com", port: 443).authority == "ghe.example.com")
    }

    @Test func apiURLAppendsEndpointRelativeToBase() {
        let dotCom = GitHubHost.dotCom.apiURL(endpoint: "repos/acme/widgets/pulls?state=all")
        let enterprise = GitHubHost(hostname: "ghe.example.com")
            .apiURL(endpoint: "repos/acme/widgets/pulls?state=all")

        #expect(dotCom?.absoluteString == "https://api.github.com/repos/acme/widgets/pulls?state=all")
        #expect(enterprise?.absoluteString == "https://ghe.example.com/api/v3/repos/acme/widgets/pulls?state=all")
    }
}

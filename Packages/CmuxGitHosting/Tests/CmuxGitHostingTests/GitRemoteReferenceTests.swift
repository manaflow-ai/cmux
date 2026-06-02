import Testing
@testable import CmuxGitHosting
import Foundation

@Suite struct GitRemoteReferenceTests {
    @Test func parsesGitHubScpRemote() throws {
        let ref = try #require(GitRemoteReference.parse(remoteURL: "git@github.com:manaflow-ai/cmux.git"))
        #expect(ref.host == "github.com")
        #expect(ref.path == "manaflow-ai/cmux")
        #expect(ref.owner == "manaflow-ai")
        #expect(ref.name == "cmux")
        #expect(ref.identity == "github.com/manaflow-ai/cmux")
        #expect(ref.httpsPort == nil)
    }

    @Test func parsesGitHubHttpsRemote() throws {
        let ref = try #require(GitRemoteReference.parse(remoteURL: "https://github.com/manaflow-ai/cmux.git"))
        #expect(ref.host == "github.com")
        #expect(ref.path == "manaflow-ai/cmux")
    }

    @Test func parsesEnterpriseHostVerbatim() throws {
        let ref = try #require(GitRemoteReference.parse(remoteURL: "git@ghe.example.com:team/app.git"))
        #expect(ref.host == "ghe.example.com")
        #expect(ref.path == "team/app")
        #expect(ref.identity == "ghe.example.com/team/app")
    }

    @Test func preservesGitLabSubgroupPath() throws {
        let ref = try #require(GitRemoteReference.parse(remoteURL: "git@gitlab.com:group/subgroup/app.git"))
        #expect(ref.host == "gitlab.com")
        #expect(ref.path == "group/subgroup/app")
        #expect(ref.owner == "group")
        #expect(ref.name == "app")
    }

    @Test func capturesHttpsPortButIgnoresSshPort() throws {
        let https = try #require(GitRemoteReference.parse(remoteURL: "https://gitlab.example.com:8443/team/app.git"))
        #expect(https.host == "gitlab.example.com")
        #expect(https.httpsPort == 8443)
        #expect(https.hostWithPort == "gitlab.example.com:8443")
        #expect(https.identity == "gitlab.example.com:8443/team/app")

        let ssh = try #require(GitRemoteReference.parse(remoteURL: "ssh://git@gitlab.example.com:2222/team/app.git"))
        #expect(ssh.host == "gitlab.example.com")
        #expect(ssh.httpsPort == nil)
    }

    @Test func parsesBitbucketRemote() throws {
        let ref = try #require(GitRemoteReference.parse(remoteURL: "https://bitbucket.org/workspace/repo.git"))
        #expect(ref.host == "bitbucket.org")
        #expect(ref.path == "workspace/repo")
    }

    @Test func parsesWebURL() throws {
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/42"))
        let ref = try #require(GitRemoteReference.parse(webURL: url))
        #expect(ref.host == "github.com")
        #expect(ref.path == "manaflow-ai/cmux/pull/42")
    }

    @Test func rejectsRemoteWithoutOwnerAndRepo() {
        #expect(GitRemoteReference.parse(remoteURL: "git@github.com:cmux.git") == nil)
        #expect(GitRemoteReference.parse(remoteURL: "") == nil)
        #expect(GitRemoteReference.parse(remoteURL: "not a url") == nil)
    }
}

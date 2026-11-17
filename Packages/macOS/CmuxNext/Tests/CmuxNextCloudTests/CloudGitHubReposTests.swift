@testable import CmuxNextCloud
import Foundation
import Testing

/// The new chat folder picker's repository list (`GET /v1/integrations/github/repos`) and the status's
/// `repos_scope`: which answers list rows, which mean the App is not installed, and what reaches the URL.
struct CloudGitHubReposTests {
    static func body(_ text: String) -> Data { Data(text.utf8) }

    @Test func listsTheRowsThatNameARepository() throws {
        let answer = Self.body(#"""
        {"repos":[{"full_name":"acme/api","private":true,"default_branch":"main"},
                  {"full_name":"acme/web","private":false,"default_branch":null},
                  {"full_name":"not a repo","private":false},
                  {"full_name":"acme/..","private":false},
                  "junk"],
         "truncated":true}
        """#)
        let listed = try CloudGitHubRepos.parse(status: 200, body: answer).get()
        #expect(listed.repos == [.init(fullName: "acme/api", isPrivate: true, defaultBranch: "main"),
                                 .init(fullName: "acme/web", isPrivate: false, defaultBranch: nil)])
        #expect(listed.truncated)
    }

    @Test func anOlderWorkersCursorMeansTruncated() throws {
        let paged = try CloudGitHubRepos.parse(status: 200, body: Self.body(#"{"repos":[],"cursor":"abc"}"#)).get()
        #expect(paged.truncated)
        let last = try CloudGitHubRepos.parse(status: 200, body: Self.body(#"{"repos":[],"cursor":null}"#)).get()
        #expect(!last.truncated)
    }

    @Test(arguments: [
        (404, #"{"error":{"code":"integration.not_found","message":"this team has no GitHub connection"}}"#, CloudGitHubRepos.Failure.notConnected),
        (409, #"{"error":{"code":"needs_reauth","message":"link GitHub again"}}"#, .notConnected),
        (503, #"{"error":{"code":"integration.unavailable","message":"GitHub did not answer"}}"#, .unavailable),
        (404, "not found", .unavailable),
        (401, #"{"error":{"code":"auth.required","message":"sign in"}}"#, .unavailable),
        (200, #"{"configured":true}"#, .unavailable),
    ])
    func everyOtherAnswerSaysWhy(status: Int, text: String, expected: CloudGitHubRepos.Failure) {
        #expect(CloudGitHubRepos.parse(status: status, body: Self.body(text)) == .failure(expected))
    }

    @Test func onlyATeamAndAnEncodedQueryReachTheURL() {
        #expect(CloudGitHubRepos.path(team: "team_01HZX9", query: nil) == "/v1/integrations/github/repos?team=team_01HZX9")
        #expect(CloudGitHubRepos.path(team: "team_01HZX9", query: "  ") == "/v1/integrations/github/repos?team=team_01HZX9")
        #expect(CloudGitHubRepos.path(team: "team_01HZX9", query: "a b&team=x") == "/v1/integrations/github/repos?team=team_01HZX9&query=a%20b%26team%3Dx")
        #expect(CloudGitHubRepos.path(team: "team_a&b=c", query: "x") == nil)
        #expect(CloudGitHubRepos.path(team: "01HZX9", query: nil) == nil)
    }

    @Test func aReadyConnectionSaysWhichRepositoriesItReaches() {
        let all = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"active","repos":null}}"#)
        let selected = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"active","repos":["acme/api"]}}"#)
        let none = Self.body(#"{"configured":true,"app_slug":"cmux","connection":null}"#)
        #expect(CloudGitHubApp.reposScope(status: 200, body: all) == "all")
        #expect(CloudGitHubApp.reposScope(status: 200, body: selected) == "selected")
        #expect(CloudGitHubApp.reposScope(status: 200, body: none) == nil)
    }
}

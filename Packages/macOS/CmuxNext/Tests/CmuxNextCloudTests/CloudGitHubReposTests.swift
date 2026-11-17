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

    @Test func aFullNameFollowsGitHubsRules() {
        for name in ["acme/api", "a-b/x.y_z", "A1/repo.js"] { #expect(CloudGitHubRepos.isFullName(name), "\(name)") }
        for name in ["-acme/api", "acme-/api", "acme/.git", "acme/..", "acme/a/b", "acme/", "/api", "acme/a b", "acme/a;b"] {
            #expect(!CloudGitHubRepos.isFullName(name), "\(name)")
        }
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

    /// More repositories: a ready connection's installation settings, only on github.com, absent from an older Worker.
    @Test func aReadyConnectionNamesItsInstallationSettings() {
        func status(_ connection: String) -> Data { Self.body(#"{"configured":true,"app_slug":"cmux","connection":\#(connection)}"#) }
        let user = status(#"{"status":"active","repos":null,"configure_url":"https://github.com/settings/installations/42"}"#)
        let org = status(#"{"status":"active","repos":[],"configure_url":"https://github.com/organizations/acme-co/settings/installations/7"}"#)
        #expect(CloudGitHubApp.configureURL(status: 200, body: user) == URL(string: "https://github.com/settings/installations/42"))
        #expect(CloudGitHubApp.configureURL(status: 200, body: org) == URL(string: "https://github.com/organizations/acme-co/settings/installations/7"))
        for connection in [#"{"status":"active","repos":null}"#, #"{"status":"active","configure_url":null}"#,
                           #"{"status":"active","configure_url":"http://github.com/settings/installations/42"}"#,
                           #"{"status":"active","configure_url":"https://github.com.evil.example/settings/installations/42"}"#,
                           #"{"status":"active","configure_url":"https://user@github.com/settings/installations/42"}"#,
                           #"{"status":"active","configure_url":"https://github.com/settings/installations/42/../../x"}"#,
                           #"{"status":"active","configure_url":"https://github.com/login/oauth/authorize"}"#,
                           #"{"status":"pending","configure_url":"https://github.com/settings/installations/42"}"#] {
            #expect(CloudGitHubApp.configureURL(status: 200, body: status(connection)) == nil, "\(connection)")
        }
    }

    /// A connected team never reaches `integration.connect` (it would add a second connection for the same installation):
    /// it opens its installation settings, or nothing when the status names none; only a team with no connection asks.
    @Test func aConnectedTeamNeverAsksForAnotherConnection() {
        func status(_ connection: String) -> Data { Self.body(#"{"configured":true,"app_slug":"cmux","connection":\#(connection)}"#) }
        let settings = status(#"{"status":"active","configure_url":"https://github.com/settings/installations/42"}"#)
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: settings) == .open(URL(string: "https://github.com/settings/installations/42")!))
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: status(#"{"status":"active","repos":null}"#)) == .connected)
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: status(#"{"status":"active","configure_url":"https://example.com/x"}"#)) == .connected)
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: status("null")) == nil)
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: Self.body(#"{"configured":false}"#)) == .unavailable)
        #expect(CloudGitHubPicker.connectFromStatus(status: 503, body: Data()) == .unavailable)
    }

    static let page = "https://github.com/apps/cmux/installations/new?state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b" // exp 2100-01-01

    @Test func theConnectReplyOpensOnlyTheAppsInstallationPage() {
        let ok = Self.body(#"{"ok":true,"value":{"connection":{"id":"conn_1"},"authorize_url":"\#(Self.page)"}}"#)
        #expect(CloudGitHubConnects.answer(status: 200, body: ok) == .page(URL(string: Self.page)!))
        let elsewhere = Self.body(#"{"ok":true,"value":{"connection":{"id":"conn_1"},"authorize_url":"https://example.com/apps/cmux/installations/new"}}"#)
        #expect(CloudGitHubConnects.answer(status: 200, body: elsewhere) == .refused)
        let noConnection = Self.body(#"{"ok":true,"value":{"authorize_url":"\#(Self.page)"}}"#)
        #expect(CloudGitHubConnects.answer(status: 200, body: noConnection) == .refused)
        #expect(CloudGitHubConnects.answer(status: 403, body: Self.body(#"{"ok":false,"error":{"code":"policy.denied"}}"#)) == .refused)
        for status in [408, 429, 500, 503] { #expect(CloudGitHubConnects.answer(status: status, body: Data()) == .noAnswer, "\(status)") }
        #expect(CloudGitHubApp.authorizationExpiry(URL(string: Self.page)!) == Date(timeIntervalSince1970: 4_102_444_800))
    }

    /// A second click reopens the page asked before while its state holds; a lost answer keeps the key for the replay,
    /// a refusal or an expired page asks again with a new key, and each team keeps its own flow.
    @MainActor @Test func aSecondClickNeverAddsAnotherPendingConnection() async {
        var made = 0
        let connects = CloudGitHubConnects(newKey: { made += 1; return "key-\(made)" })
        var asked: [String] = []
        let page = URL(string: Self.page)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lost = await connects.page(team: "team_a", now: now) { asked.append($0); return .noAnswer }
        let replayed = await connects.page(team: "team_a", now: now) { asked.append($0); return .page(page) }
        let reopened = await connects.page(team: "team_a", now: now) { asked.append($0); return .refused } // not asked
        #expect(lost == nil)
        #expect(replayed == page)
        #expect(reopened == page)
        #expect(asked == ["key-1", "key-1"])
        let expired = await connects.page(team: "team_a", now: Date(timeIntervalSince1970: 4_102_444_801)) { asked.append($0); return .refused }
        let fresh = await connects.page(team: "team_a", now: now) { asked.append($0); return .page(page) }
        let otherTeam = await connects.page(team: "team_b", now: now) { asked.append($0); return .page(page) }
        #expect(expired == nil)
        #expect(fresh == page)
        #expect(otherTeam == page)
        #expect(asked == ["key-1", "key-1", "key-2", "key-3", "key-4"])
    }
}

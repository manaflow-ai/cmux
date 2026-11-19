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

    /// Settings' Reconfigure (#46018): the installation settings when the status names them, else the App's own
    /// installation chooser on GitHub for a well-formed slug; nothing for a connection that is not ready.
    @Test func reconfigureOpensTheInstallationSettingsOrTheAppsChooser() {
        func status(_ slug: String, _ connection: String) -> Data { Self.body(#"{"configured":true,"app_slug":"\#(slug)","connection":\#(connection)}"#) }
        let settings = status("cmux", #"{"status":"active","configure_url":"https://github.com/settings/installations/42"}"#)
        #expect(CloudGitHubApp.reconfigureURL(status: 200, body: settings) == URL(string: "https://github.com/settings/installations/42"))
        let noPage = status("cmux", #"{"status":"active","configure_url":null}"#)
        #expect(CloudGitHubApp.reconfigureURL(status: 200, body: noPage) == URL(string: "https://github.com/apps/cmux/installations/new"))
        for (slug, connection) in [("cmux", #"{"status":"pending","configure_url":null}"#), ("cmux", "null"),
                                   ("a/installations/new?x=", #"{"status":"active"}"#), ("../x", #"{"status":"active"}"#)] {
            #expect(CloudGitHubApp.reconfigureURL(status: 200, body: status(slug, connection)) == nil, "\(slug) \(connection)")
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
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: Self.body(#"{"configured":false}"#)) == .unavailable(.notConfigured))
        #expect(CloudGitHubPicker.connectFromStatus(status: 503, body: Data()) == .unavailable(.unreachable))
    }

    /// `github.status` for a signed-in person: unavailable says whether this deployment has no App or nothing answered.
    @Test func theStatusSaysWhyGitHubIsUnavailable() {
        #expect(CloudGitHubPicker.Status(.ready, reposScope: "selected") == .ready(reposScope: "selected"))
        #expect(CloudGitHubPicker.Status(.notConnected, reposScope: nil) == .notConnected)
        #expect(CloudGitHubPicker.Status(.notConfigured, reposScope: nil) == .unavailable(.notConfigured))
        #expect(CloudGitHubPicker.Status(.unknown, reposScope: nil) == .unavailable(.unreachable))
        #expect(CloudGitHubPicker.Status.ready(reposScope: "all").state == "ready")
        #expect(CloudGitHubPicker.Status.ready(reposScope: "all").reposScope == "all")
        #expect(CloudGitHubPicker.Status.ready(reposScope: "all").reason == nil)
        #expect(CloudGitHubPicker.Status.notConnected.state == "not_connected")
        #expect(CloudGitHubPicker.Status.notConnected.reposScope == nil)
        #expect(CloudGitHubPicker.Status.unavailable(.signedOut).state == "unavailable")
        #expect(CloudGitHubPicker.Status.unavailable(.signedOut).reason?.rawValue == "signed_out")
        #expect(CloudGitHubPicker.Status.unavailable(.notConfigured).reason?.rawValue == "not_configured")
        #expect(CloudGitHubPicker.Status.unavailable(.unreachable).reason?.rawValue == "unreachable")
        #expect(CloudGitHubPicker.Status.unavailable(.unreachable).reposScope == nil)
    }

    /// A connect beside a pending connection (Settings', another launch's) would add a second: the picker reads
    /// `integration.list` first unless it holds a flow of its own for the team.
    @MainActor @Test func aPendingConnectionHoldsAnotherConnect() async {
        let pending = Self.body(#"{"ok":true,"value":{"connections":[{"provider":"gmail","status":"pending"},{"provider":"github","status":"pending"}],"providers":[]}}"#)
        let active = Self.body(#"{"ok":true,"value":{"connections":[{"provider":"github","status":"active"},{"provider":"gmail","status":"pending"}],"providers":[]}}"#)
        #expect(CloudGitHubConnects.pending(status: 200, body: pending) == true)
        #expect(CloudGitHubConnects.pending(status: 200, body: active) == false)
        #expect(CloudGitHubConnects.pending(status: 200, body: Self.body(#"{"ok":false,"error":{"code":"auth.forbidden"}}"#)) == nil)
        #expect(CloudGitHubConnects.pending(status: 500, body: pending) == nil)
        let connects = CloudGitHubConnects(newKey: { "key" })
        #expect(!connects.resumable(team: "team_a"))
        _ = await connects.page(team: "team_a", now: Date()) { _ in .noAnswer }
        #expect(connects.resumable(team: "team_a"))
        #expect(!connects.resumable(team: "team_b"))
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

    /// A row's size (`size_kb`, GitHub's KB) sizes a Cloud start in it; a row without one, or a bad one, has none.
    @Test func aRowsSizeIsReadWhenGiven() throws {
        let answer = Self.body(#"{"repos":[{"full_name":"acme/api","size_kb":2048},{"full_name":"acme/web","size_kb":-1},{"full_name":"acme/x"}]}"#)
        let listed = try CloudGitHubRepos.parse(status: 200, body: answer).get()
        #expect(listed.repos.map(\.sizeKb) == [2048, nil, nil])
    }

    /// #46018: the console's hand-off link carries only the connection and a single-use handoff value, for this build only.
    @Test func theHandOffLinkIsACompletionForThisBuildOnlyAndCarriesNoCode() throws {
        let link = CloudGitHubCompletion.link(scheme: "cmux-dev-x")
        #expect(link == "cmux-dev-x://integration/complete")
        let handoff = String(repeating: "k", count: 43)
        let url = try #require(URL(string: "\(link)?connection=conn_0123456789abcdefghij&handoff=\(handoff)"))
        let completion = try #require(CloudGitHubCompletion(url: url, scheme: "cmux-dev-x"))
        #expect(completion.connection == "conn_0123456789abcdefghij")
        #expect(completion.handoff == handoff)
        let attempt = CloudGitHubAttempts.Attempt(state: "h.\(Self.statePayload).s", secret: "secret", expires: .distantFuture)
        #expect(completion.params(attempt) == ["state": attempt.state, "handoff": handoff, "attempt": "secret"])
        #expect(CloudGitHubCompletion.team(ofState: attempt.state) == "team_0123456789abcdef0123")
        // Another build's scheme, another path, the old link with a code, a bad connection or handoff value: not a completion.
        #expect(CloudGitHubCompletion(url: url, scheme: "cmux") == nil)
        #expect(!CloudGitHubCompletion.isLink(url, scheme: "cmux"))
        for raw in ["cmux-dev-x://integration/other?connection=conn_0123456789abcdefghij&handoff=\(handoff)",
                    "\(link)?state=a.b.c&code=abc&installation_id=42",
                    "\(link)?connection=conn_X&handoff=\(handoff)",
                    "\(link)?connection=conn_0123456789abcdefghij&handoff=short",
                    "\(link)?connection=conn_0123456789abcdefghij&connection=conn_ffffffffffffffffffff&handoff=\(handoff)"] {
            #expect(CloudGitHubCompletion(url: try #require(URL(string: raw)), scheme: "cmux-dev-x") == nil)
        }
        #expect(CloudGitHubCompletion.isLink(try #require(URL(string: "\(link)?state=a.b.c&code=abc")), scheme: "cmux-dev-x"))
    }

    /// The app finishes only a connect it recorded: before its state expires, one completion at a time, and a finished
    /// connection forgets its attempts; one that got no answer keeps them for the link to be opened again.
    @MainActor @Test func onlyARecordedAttemptFinishesAndAFinishedOneForgetsIt() throws {
        var made = 0
        let attempts = CloudGitHubAttempts(newSecret: { made += 1; return "secret-\(made)" })
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        let conn = "conn_0123456789abcdefghij"
        let secret = attempts.secret(forKey: "key-1", now: now)
        // A retry of the same key asks with the same secret (its params must not change); another key gets another.
        #expect(attempts.secret(forKey: "key-1", now: now) == secret)
        #expect(attempts.secret(forKey: "key-2", now: now) != secret)
        let page = try #require(URL(string: "https://github.com/apps/cmux/installations/new?state=\(Self.state(hash: CloudGitHubAttempts.hash(secret), exp: 4_000_000_600))"))
        // An answer under a key that asked no secret, or whose state names another hash, records nothing.
        attempts.record(page: page, key: "key-unknown", now: now)
        attempts.record(page: page, key: "key-2", now: now)
        #expect(attempts.begin(connection: conn, now: now) == nil)
        attempts.record(page: page, key: "key-1", now: now)
        // Unsolicited: another connection. Expired: past the state's exp.
        #expect(attempts.begin(connection: "conn_ffffffffffffffffffff", now: now) == nil)
        #expect(attempts.begin(connection: conn, now: Date(timeIntervalSince1970: 4_000_000_601)) == nil)
        attempts.record(page: page, key: "key-1", now: now)
        // A replayed connect's newer state is kept beside the first, newest first.
        let replay = try #require(URL(string: "https://github.com/apps/cmux/installations/new?state=\(Self.state(hash: CloudGitHubAttempts.hash(secret), exp: 4_000_000_700))"))
        attempts.record(page: replay, key: "key-1", now: now)
        let first = try #require(attempts.begin(connection: conn, now: now))
        #expect(first.map(\.expires.timeIntervalSince1970) == [4_000_000_700, 4_000_000_600])
        #expect(first.allSatisfy { $0.secret == secret })
        // One completion at a time; no answer keeps both; a refused one goes; a finished connection forgets the rest.
        #expect(attempts.begin(connection: conn, now: now) == nil)
        attempts.end(connection: conn, finished: false, spent: [])
        let again = try #require(attempts.begin(connection: conn, now: now))
        attempts.end(connection: conn, finished: false, spent: [again[0]])
        #expect(try #require(attempts.begin(connection: conn, now: now)).count == 1)
        attempts.end(connection: conn, finished: true, spent: [])
        #expect(attempts.begin(connection: conn, now: now) == nil)
        // The hash is base64url SHA-256 without padding, the API's attempt_hash form.
        #expect(CloudGitHubAttempts.hash("abc") == "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0")
        #expect(CloudGitHubAttempts.randomSecret().range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil)
    }

    static func state(hash: String, exp: Int) -> String {
        let claims = #"{"conn":"conn_0123456789abcdefghij","team":"team_0123456789abcdef0123","exp":\#(exp),"anh":"\#(hash)"}"#
        let payload = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "h.\(payload).s"
    }

    @Test func aCompletionIsConnectedOnlyWhenTheAPISaysOk() {
        #expect(CloudOwnerAPIClient.completion(status: 200, body: Self.body(#"{"ok":true,"value":{}}"#)) == .connected)
        #expect(CloudOwnerAPIClient.completion(status: 200, body: Self.body(#"{"ok":false,"error":{"code":"integration.state_invalid"}}"#)) == .refused)
        #expect(CloudOwnerAPIClient.completion(status: 403, body: Self.body("{}")) == .refused)
        #expect(CloudOwnerAPIClient.completion(status: 503, body: Data()) == .noAnswer)
        #expect(CloudOwnerAPIClient.completion(status: 429, body: Data()) == .noAnswer)
    }

    static let statePayload = "eyJ0ZWFtIjoidGVhbV8wMTIzNDU2Nzg5YWJjZGVmMDEyMyIsInJldCI6ImNtdXgtZGV2LXg6Ly9pbnRlZ3JhdGlvbi9jb21wbGV0ZSJ9"
}

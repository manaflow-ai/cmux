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

    /// A pending connection never blocks Connect (#46018): one from another launch, or one whose return failed, can't
    /// be finished here, so a click asks `integration.connect` again (it expires on its own after 30 minutes).
    @Test func aPendingConnectionStillConnects() {
        let linking = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"pending"}}"#)
        #expect(CloudGitHubApp(status: 200, body: linking) == .linking)
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: linking) == nil, "nil: the picker asks integration.connect")
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

    /// #55104: a Cloud start card's Connect for one repository. The API reuses a connection that already covers it
    /// (`connected: true`, nothing to open), and for an owner the App is installed on answers GitHub's authorize page,
    /// never the person's own installation settings (whose save comes back with no state and asks a web sign-in).
    @Test func aRepositoryConnectOpensTheAuthorizePageOrNothingWhenCovered() {
        let covered = Self.body(#"{"ok":true,"value":{"connection":{"id":"conn_1","status":"active"},"connected":true}}"#)
        #expect(CloudGitHubConnects.answer(status: 200, body: covered) == .connected)
        let authorize = "https://github.com/login/oauth/authorize?client_id=Iv1&state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"
        let installed = Self.body(#"{"ok":true,"value":{"connection":{"id":"conn_2"},"authorize_url":"\#(authorize)"}}"#)
        #expect(CloudGitHubConnects.answer(status: 200, body: installed) == .page(URL(string: authorize)!))
        let forOwner = "https://github.com/apps/cmux/installations/new/permissions?target_id=7&state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"
        let install = Self.body(#"{"ok":true,"value":{"connection":{"id":"conn_3"},"authorize_url":"\#(forOwner)"}}"#)
        #expect(CloudGitHubConnects.answer(status: 200, body: install) == .page(URL(string: forOwner)!))
        let settings = Self.body(#"{"ok":true,"value":{"connection":{"id":"conn_4"},"authorize_url":"https://github.com/settings/installations/183460287"}}"#)
        #expect(CloudGitHubConnects.answer(status: 200, body: settings) == .refused, "a settings page carries no state: never a connect page")
        let noConnection = Self.body(#"{"ok":true,"value":{"connected":true}}"#)
        #expect(CloudGitHubConnects.answer(status: 200, body: noConnection) == .refused)
    }

    /// #55104: a team whose connection is ready (on the person's own account) still asks the API for a repository card's
    /// Connect, instead of opening that installation's settings; only a missing App or no answer settles it from status.
    @MainActor @Test func aRepositoryConnectAsksTheAPIEvenWhenTheTeamIsReady() {
        let ready = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"active","configure_url":"https://github.com/settings/installations/183460287"}}"#)
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: ready) == .open(URL(string: "https://github.com/settings/installations/183460287")!))
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: ready, repo: "manaflow-ai/cmuxterm-hq") == nil)
        let missing = Self.body(#"{"configured":false}"#)
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: missing, repo: "acme/api") == CloudGitHubPicker.connectFromStatus(status: 200, body: missing))
        #expect(CloudGitHubPicker.connectFromStatus(status: 503, body: Data(), repo: "acme/api") == .unavailable(.unreachable))
        // A suspended install on the repository's owner opens its settings page (only it lifts the suspension); one on
        // another account, or a personal page that names no account, asks the API.
        let suspended = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"needs_reauth","configure_url":"https://github.com/organizations/acme/settings/installations/7"}}"#)
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: suspended, repo: "ACME/api") == .open(URL(string: "https://github.com/organizations/acme/settings/installations/7")!))
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: suspended, repo: "other/api") == nil)
        let personal = Self.body(#"{"configured":true,"app_slug":"cmux","connection":{"status":"needs_reauth","configure_url":"https://github.com/settings/installations/7"}}"#)
        #expect(CloudGitHubPicker.connectFromStatus(status: 200, body: personal, repo: "acme/api") == nil)
    }

    /// Each repository card keeps its own flow: one repository's page is never reopened for another, and a covered
    /// answer asks again next time (the connection may change).
    @MainActor @Test func eachRepositoryConnectKeepsItsOwnFlow() async {
        var made = 0
        let connects = CloudGitHubConnects(newKey: { made += 1; return "key-\(made)" })
        let page = URL(string: Self.page)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(await connects.answer(team: "team_a", repo: "acme/api", now: now) { _ in .page(page) } == .page(page))
        #expect(await connects.answer(team: "team_a", repo: "ACME/api", now: now) { _ in .refused } == .page(page), "same repository, any case")
        #expect(await connects.answer(team: "team_a", repo: "acme/web", now: now) { _ in .connected } == .connected)
        #expect(await connects.answer(team: "team_a", repo: "acme/web", now: now) { _ in .refused } == .refused)
        #expect(await connects.page(team: "team_a", now: now) { _ in .connected } == nil, "the folder menu's page opens nothing for connected")
        // A finished completion spends every page: the next click asks again instead of reopening a used state.
        connects.forgetPages()
        let fresh = URL(string: "https://github.com/login/oauth/authorize?state=x.eyJleHAiOjQxMDI0NDQ4MDB9.y")!
        #expect(await connects.answer(team: "team_a", repo: "acme/api", now: now) { _ in .page(fresh) } == .page(fresh))
    }

    /// A row's size (`size_kb`, GitHub's KB) sizes a Cloud start in it; a row without one, or a bad one, has none.
    @Test func aRowsSizeIsReadWhenGiven() throws {
        let answer = Self.body(#"{"repos":[{"full_name":"acme/api","size_kb":2048},{"full_name":"acme/web","size_kb":-1},{"full_name":"acme/x"}]}"#)
        let listed = try CloudGitHubRepos.parse(status: 200, body: answer).get()
        #expect(listed.repos.map(\.sizeKb) == [2048, nil, nil])
    }

    /// #46018: GitHub's install redirect comes back to this build's own link, and the app completes it with its sign-in.
    @Test func theInstallRedirectHandedBackToTheAppIsACompletionForThisBuildOnly() throws {
        let state = "h.\(Self.statePayload).s"
        let link = CloudGitHubCompletion.link(scheme: "cmux-dev-x")
        #expect(link == "cmux-dev-x://integration/complete")
        let url = try #require(URL(string: "\(link)?state=\(state)&code=abc&installation_id=42&setup_action=install"))
        let completion = try #require(CloudGitHubCompletion(url: url, scheme: "cmux-dev-x"))
        #expect(completion.params == ["state": state, "code": "abc", "installation_id": "42", "setup_action": "install"])
        #expect(completion.team == "team_0123456789abcdef0123")
        // The console's key for the same redirect (dashboard integration-callback.test.ts pins 9f146c4dbeb30218 too).
        #expect(completion.idempotencyKey == "complete:" + String(state.suffix(40)) + ":9f146c4dbeb30218")
        #expect(completion.error == nil)
        // #55104: another redirect of the same state (the code-less update, a new installation) is its own completion,
        // never `idempotency.conflict`; the same redirect again is the same completion.
        // One #require per line: a #require nested in another's argument is a recursive macro expansion,
        // which fails the test build.
        let updateURL = try #require(URL(string: "\(link)?state=\(state)&installation_id=42&setup_action=update"))
        let update = try #require(CloudGitHubCompletion(url: updateURL, scheme: "cmux-dev-x"))
        let otherInstallURL = try #require(URL(string: "\(link)?state=\(state)&code=abc&installation_id=43&setup_action=install"))
        let otherInstall = try #require(CloudGitHubCompletion(url: otherInstallURL, scheme: "cmux-dev-x"))
        #expect(Set([completion.idempotencyKey, update.idempotencyKey, otherInstall.idempotencyKey]).count == 3)
        #expect(try #require(CloudGitHubCompletion(url: url, scheme: "cmux-dev-x")).idempotencyKey == completion.idempotencyKey)
        #expect(completion.idempotencyKey.count <= 128)
        // Another build's scheme, another path, no signed state: not a completion.
        #expect(CloudGitHubCompletion(url: url, scheme: "cmux") == nil)
        let otherPath = try #require(URL(string: "cmux-dev-x://integration/other?state=\(state)"))
        let noState = try #require(URL(string: "cmux-dev-x://integration/complete?code=abc"))
        #expect(CloudGitHubCompletion(url: otherPath, scheme: "cmux-dev-x") == nil)
        #expect(CloudGitHubCompletion(url: noState, scheme: "cmux-dev-x") == nil)
        // A cancel on GitHub carries its error; an installation id that is not a number is not sent.
        let cancelURL = try #require(URL(string: "\(link)?state=\(state)&error=access_denied&installation_id=1;x"))
        let cancelled = try #require(CloudGitHubCompletion(url: cancelURL, scheme: "cmux-dev-x"))
        #expect(cancelled.error == "access_denied")
        #expect(cancelled.params == ["state": state])
        // A state whose team claim is not a team id routes nowhere.
        let opaqueURL = try #require(URL(string: "\(link)?state=a.b.c"))
        let opaque = try #require(CloudGitHubCompletion(url: opaqueURL, scheme: "cmux-dev-x"))
        #expect(opaque.team == nil)
    }

    @Test func aCompletionIsConnectedOnlyWhenTheAPISaysOk() {
        #expect(CloudOwnerAPIClient.completion(status: 200, body: Self.body(#"{"ok":true,"value":{}}"#)) == .connected)
        #expect(CloudOwnerAPIClient.completion(status: 200, body: Self.body(#"{"ok":false,"error":{"code":"integration.state_invalid"}}"#)) == .refused(message: nil))
        #expect(CloudOwnerAPIClient.completion(status: 403, body: Self.body("{}")) == .refused(message: nil))
        #expect(CloudOwnerAPIClient.completion(status: 503, body: Data()) == .noAnswer)
        #expect(CloudOwnerAPIClient.completion(status: 429, body: Data()) == .noAnswer)
    }

    /// A refused completion carries the API's words for the person (an expired state, another person's state).
    @Test func aRefusedCompletionCarriesTheAPIsMessage() {
        let refused = Self.body(#"{"ok":false,"error":{"code":"integration.state_invalid","message":"integration state expired"}}"#)
        #expect(CloudOwnerAPIClient.completion(status: 400, body: refused) == .refused(message: "integration state expired"))
        #expect(CloudOwnerAPIClient.completion(status: 200, body: refused) == .refused(message: "integration state expired"))
        #expect(CloudOwnerAPIClient.completion(status: 400, body: Self.body(#"{"ok":false,"error":{"code":"x","message":"  "}}"#)) == .refused(message: nil))
    }

    /// An organization member's install comes back as `setup_action=request` with no installation: the API's refusal
    /// of it reads as an owner's approval pending, not as an error; a request that did bring an installation does not.
    @Test func anOwnerRequestReadsAsPendingApproval() throws {
        let state = "h.\(Self.statePayload).s"
        let link = CloudGitHubCompletion.link(scheme: "cmux-dev-x")
        let requestURL = try #require(URL(string: "\(link)?state=\(state)&setup_action=request"))
        let request = try #require(CloudGitHubCompletion(url: requestURL, scheme: "cmux-dev-x"))
        #expect(request.isOwnerRequest)
        let installedURL = try #require(URL(string: "\(link)?state=\(state)&installation_id=7&setup_action=request"))
        let installed = try #require(CloudGitHubCompletion(url: installedURL, scheme: "cmux-dev-x"))
        #expect(!installed.isOwnerRequest)
        let said = "GitHub sent your request to install the cmux GitHub App to the organization's owners. When an owner approves it, choose Connect GitHub in cmux again"
        let refused = Self.body(#"{"ok":false,"error":{"code":"integration.state_invalid","message":"\#(said)"}}"#)
        #expect(CloudOwnerAPIClient.completion(status: 400, body: refused, ownerRequest: true) == .pendingApproval(message: said))
        #expect(CloudOwnerAPIClient.completion(status: 503, body: Data(), ownerRequest: true) == .noAnswer)
        #expect(CloudOwnerAPIClient.completion(status: 200, body: Self.body(#"{"ok":true,"value":{}}"#), ownerRequest: true) == .connected)
    }

    @Test func aRefusedCompletionKeepsTheAPIsReasonUnlessItIsTheExpiredState() {
        #expect(CloudOwnerAPIClient.refusalReason(body: Self.body(#"{"error":{"code":"integration.state_invalid","message":"state expired"}}"#)) == nil)
        #expect(CloudOwnerAPIClient.refusalReason(body: Self.body(#"{"error":{"code":"integration.forbidden","message":" Only an owner of acme can connect GitHub. "}}"#))
                == "Only an owner of acme can connect GitHub.")
        #expect(CloudOwnerAPIClient.refusalReason(body: Self.body(#"{"error":{"code":"integration.forbidden"}}"#)) == nil)
        #expect(CloudOwnerAPIClient.refusalReason(body: Self.body("not json")) == nil)
    }

    @MainActor @Test func theLastAnswerStaysOnTheChangesUntilTheNextOneOrANewConnect() {
        let changes = CloudGitHubChanges()
        changes.record(.refused(message: nil), reason: nil)
        #expect(changes.refusal == CloudGitHubChanges.Refusal(reason: nil))
        #expect(changes.count == 1)
        changes.record(.refused(message: nil), reason: "Only an owner can connect.")
        #expect(changes.refusal?.reason == "Only an owner can connect.")
        changes.forgetRefusal()
        #expect(changes.refusal == nil)
        changes.record(.refused(message: nil), reason: nil)
        changes.record(.connected, reason: nil)
        #expect(changes.refusal == nil, "a connection clears the last refusal")
        changes.record(.refused(message: nil), reason: nil)
        changes.record(.noAnswer, reason: nil)
        #expect(changes.refusal == nil, "a lost answer proves nothing, and the person is told nothing wrong")
        #expect(changes.count == 6)
    }

    static let statePayload = "eyJ0ZWFtIjoidGVhbV8wMTIzNDU2Nzg5YWJjZGVmMDEyMyIsInJldCI6ImNtdXgtZGV2LXg6Ly9pbnRlZ3JhdGlvbi9jb21wbGV0ZSJ9"
}

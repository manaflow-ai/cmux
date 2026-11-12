import CmuxNextActions
import CmuxNextAccounts
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

@MainActor
@Suite struct GitHubConnectionsTests {
    private let scope = GitHubConnections.Scope(user: "user", team: nil)
    private var listing: JSONValue {
        ["connections": .array([]), "providers": [["provider": "github", "configured": true]]]
    }

    @Test func signedOutNeverCallsTheAPI() async {
        var calls = 0
        let model = GitHubConnections(scope: { nil }, call: { _, _, _, _ in calls += 1; return self.listing }, open: { _ in })
        await model.perform("githubConnect")
        await model.perform("githubRefresh")
        await model.connect()
        #expect(model.pageState["outcome"] == "needs-action")
        // Msg 3790: the signed-out card offers the Sign In button.
        #expect(model.pageState["signIn"]?.stringValue?.isEmpty == false)
        #expect(calls == 0)
        #expect(!model.ready)
    }

    @Test func connectUsesTheAppInstallPageAndDoesNotPretendItIsConnected() async {
        var operations: [String] = []
        var opened: [URL] = []
        var connected = false
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, params, mutation in
            operations.append(op)
            if op == "integration.connect" {
                #expect(params == ["provider": "github"])
                #expect(mutation != nil)
                connected = true
                return ["connection": ["id": "sample"], "authorize_url": "https://github.com/apps/cmux/installations/new?state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"]
            }
            if connected { return ["connections": [["id": "sample", "provider": "github", "status": "pending"]], "providers": [["provider": "github", "configured": true]]] }
            return self.listing
        }, open: { opened.append($0) })
        await model.perform("githubRefresh")
        #expect(model.ready)
        await model.perform("githubConnect")
        #expect(operations == ["integration.list", "integration.connect", "integration.list"])
        #expect(opened.count == 1)
        #expect(model.pending)
        #expect(model.currentConnections.first?["status"] == "pending")
        await model.perform("githubConnect")
        #expect(operations.filter { $0 == "integration.connect" }.count == 1)
        #expect(opened.count == 2)
    }

    @Test func aResponseForTheOldAccountCannotPopulateTheNewAccount() async {
        var current: GitHubConnections.Scope? = self.scope
        let model = GitHubConnections(scope: { current }, call: { _, _, _, _ in
            current = .init(user: "another-user", team: nil)
            return ["connections": [["id": "old", "provider": "github", "status": "active"]], "providers": [["provider": "github", "configured": true]]]
        }, open: { _ in })
        await model.perform("githubRefresh")
        #expect(model.currentConnections.isEmpty)
        #expect(!model.ready)
        #expect(!model.busy)
    }

    @Test func unknownConnectionCannotBeRevoked() async {
        var calls = 0
        let model = GitHubConnections(scope: { self.scope }, call: { _, _, _, _ in calls += 1; return self.listing }, open: { _ in })
        await model.perform("githubDisconnect", connection: "not-captured")
        #expect(calls == 0)
    }

    @Test func disconnectOnlyChangesAnOwnedConnectionAndRefreshesItsState() async {
        var operations: [String] = []
        var revoked = false
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, params, mutation in
            operations.append(op)
            if op == "integration.revoke" {
                #expect(params == ["connection": "mine"])
                #expect(mutation != nil)
                revoked = true
                return [:]
            }
            return ["connections": [
                ["id": "mine", "provider": "github", "created_by": "user", "status": revoked ? "revoked" : "active"],
                ["id": "shared", "provider": "github", "created_by": "another-user", "status": "active"],
            ], "providers": [["provider": "github", "configured": true]]]
        }, open: { _ in })
        await model.perform("githubRefresh")
        await model.perform("githubDisconnect", connection: "shared")
        #expect(operations == ["integration.list"])
        await model.perform("githubDisconnect", connection: "mine")
        #expect(operations == ["integration.list", "integration.revoke", "integration.list"])
        #expect(model.currentConnections.count == 1)
        #expect(model.currentConnections.first?["id"] == "shared")
    }

    @Test func failedRefreshHasRecoveryAndDoesNotEraseKnownConnections() async {
        var fail = false
        var current = self.scope
        let model = GitHubConnections(scope: { current }, call: { _, _, _, _ in
            if fail { throw GitHubConnections.GitHubFailure.refused }
            return self.listing
        }, open: { _ in })
        await model.perform("githubRefresh")
        fail = true
        await model.perform("githubRefresh")
        #expect(model.error)
        #expect(model.pageState["refresh"]?.stringValue?.isEmpty == false)
        current = .init(user: "another-user", team: nil)
        #expect(!model.error)
        #expect(!model.ready)
    }

    @Test func lostConnectResponseReusesItsIdempotencyKey() async {
        var keys: [String?] = []
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, _, key in
            if op == "integration.connect" {
                keys.append(key)
                if keys.count == 1 { throw URLError(.networkConnectionLost) }
                return ["connection": ["id": "sample"], "authorize_url": "https://github.com/apps/cmux/installations/new?state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"]
            }
            return self.listing
        }, open: { _ in })
        await model.connect()
        #expect(model.error)
        await model.connect()
        #expect(keys.count == 2)
        #expect(keys.first! != nil)
        #expect(keys[0] == keys[1])
    }

    @Test func aLostConnectResponseWithAServerPendingRowRetriesUnderItsKey() async {
        var keys: [String?] = []
        var opened: [URL] = []
        var created = false
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, _, key in
            if op == "integration.connect" {
                keys.append(key)
                created = true
                if keys.count == 1 { throw URLError(.networkConnectionLost) }
                return ["connection": ["id": "sample"], "authorize_url": "https://github.com/apps/cmux/installations/new?state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"]
            }
            // The lost connect did create the server's pending row.
            let rows: [JSONValue] = created ? [["id": "sample", "provider": "github", "created_by": "user", "status": "pending"]] : []
            return ["connections": .array(rows), "providers": [["provider": "github", "configured": true]]]
        }, open: { opened.append($0) })
        await model.connect()
        #expect(model.error)
        #expect(model.canConnect, "the held key makes the pending flow resumable")
        await model.connect()
        #expect(keys.count == 2)
        #expect(keys[0] != nil && keys[0] == keys[1])
        #expect(opened.count == 1)
    }

    @Test func policyRejectionDoesNotReplayAfterPolicyChanges() async throws {
        var keys: [String] = []
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, _, key in
            if op == "integration.connect" {
                keys.append(try #require(key))
                if keys.count == 1 { throw GitHubConnections.GitHubFailure.refused }
                return ["connection": ["id": "sample"], "authorize_url": "https://github.com/apps/cmux/installations/new?state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"]
            }
            return self.listing
        }, open: { _ in })
        await model.connect()
        #expect(model.error)
        await model.connect()
        #expect(!model.error)
        try #require(keys.count == 2)
        #expect(keys[0] != keys[1])
    }

    @Test func aRefusalFromAnOlderGenerationCannotClearANewKey() async throws {
        var current: GitHubConnections.Scope? = self.scope
        let requests = AsyncStream<CheckedContinuation<JSONValue, Error>>.makeStream()
        var events = requests.stream.makeAsyncIterator()
        var keys: [String] = []
        let model = GitHubConnections(scope: { current }, call: { _, op, _, key in
            guard op == "integration.connect" else { return self.listing }
            keys.append(try #require(key))
            if keys.count == 1 || keys.count == 3 {
                return try await withCheckedThrowingContinuation { requests.continuation.yield($0) }
            }
            throw GitHubConnections.GitHubFailure.refused
        }, open: { _ in })
        let first = Task {
            await model.connect()
            requests.continuation.finish()
        }
        let oldest = try #require(await events.next())
        current = .init(user: "other", team: nil)
        await model.perform("githubRefresh")
        current = self.scope
        await model.connect() // Current refusal of K1 permits a new key.
        let second = Task {
            await model.connect()
            requests.continuation.finish()
        }
        let latest = try #require(await events.next())
        oldest.resume(throwing: GitHubConnections.GitHubFailure.refused)
        await first.value
        latest.resume(throwing: URLError(.networkConnectionLost))
        await second.value
        await model.connect()
        try #require(keys.count == 4)
        #expect(keys[0] == keys[1])
        #expect(keys[1] != keys[2])
        #expect(keys[2] == keys[3]) // Obsolete K1 failure must not discard K2.
    }

    @Test func managedTeamCannotFallBackToPersonalIntegration() async {
        var team: String?
        var calls = 0
        let model = GitHubConnections(scope: {
            GitHubConnections.signedInScope(project: "project", user: "user", team: team, managedTeam: "managed")
        }, call: { bound, _, _, _ in
            calls += 1
            #expect(bound.team == "managed")
            return self.listing
        }, open: { _ in })
        await model.connect()
        #expect(calls == 0)
        team = "another-team"
        await model.connect()
        #expect(calls == 0)
        team = "managed"
        await model.perform("githubRefresh")
        #expect(calls == 1)
        #expect(model.ready)
        #expect(GitHubConnections.signedInScope(project: "project", user: "user", team: nil, managedTeam: nil)?.team == nil)
        #expect(GitHubConnections.signedInScope(project: "project", user: "user", team: nil, managedTeam: nil) != nil)
    }

    @Test func restoredPendingConnectionDoesNotCreateADuplicate() async {
        var connects = 0
        var opened = 0
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, _, _ in
            if op == "integration.connect" { connects += 1 }
            return ["connections": [["id": "pending", "provider": "github", "created_by": "user", "status": "pending"]], "providers": [["provider": "github", "configured": true]]]
        }, open: { _ in opened += 1 })
        await model.connect()
        #expect(model.pageState["canConnect"] == false)
        #expect(model.pageState["outcome"] == "pending")
        await model.perform("githubConnect")
        #expect(connects == 0)
        #expect(opened == 0)
    }

    @Test func sharedConnectDoesNotCreateAnotherActiveConnection() async {
        var connects = 0
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, _, _ in
            if op == "integration.connect" { connects += 1 }
            return ["connections": [["id": "mine", "provider": "github", "created_by": "user", "status": "active"]], "providers": [["provider": "github", "configured": true]]]
        }, open: { _ in })
        await model.connect()
        await model.connect()
        #expect(connects == 0)
        #expect(model.pageState["outcome"] == "connected")
    }

    @Test func anActiveSharedConnectionIsConnectedButCannotBeRevoked() async {
        var mutations = 0
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, _, _ in
            if op != "integration.list" { mutations += 1 }
            return ["connections": [["id": "shared", "provider": "github", "created_by": "another-user", "sharing": "team", "status": "active"]], "providers": [["provider": "github", "configured": true]]]
        }, open: { _ in })
        await model.connect()
        await model.perform("githubDisconnect", connection: "shared")
        #expect(model.connected)
        #expect(model.pageState["outcome"] == "connected")
        #expect(model.pageState["canConnect"] == false)
        #expect(model.pageState["connections"]?.arrayValue?.first?["canDisconnect"] == false)
        #expect(mutations == 0)
    }

    @Test func anExpiredAuthorizationStartsANewAttempt() async {
        var clock = Date(timeIntervalSince1970: 4102444799)
        var keys: [String?] = []
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, _, key in
            if op == "integration.connect" {
                keys.append(key)
                return ["connection": ["id": "sample"], "authorize_url": "https://github.com/apps/cmux/installations/new?state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"]
            }
            if keys.isEmpty { return self.listing }
            return ["connections": [["id": "sample", "provider": "github", "status": "pending"]], "providers": [["provider": "github", "configured": true]]]
        }, open: { _ in }, now: { clock })
        await model.connect()
        clock = clock.addingTimeInterval(1)
        await model.connect()
        #expect(keys.count == 2)
        #expect(keys[0] != keys[1])
    }

    @Test func theCLIReportsAConnectionFailureAsFailure() async {
        let model = GitHubConnections(scope: { self.scope }, call: { _, _, _, _ in throw GitHubConnections.GitHubFailure.refused }, open: { _ in })
        let result = await model.connectResult()
        guard case .failure(let error) = result else { Issue.record("the command reported success after a failed request"); return }
        #expect(!error.message.isEmpty)
        #expect(model.pageState["outcome"] == "failed")
    }

    @Test func theGuideAndCLIShareAWaitingConnectAction() throws {
        let action = try #require(ActionRegistry.standard().descriptor(for: "accounts.githubConnect"))
        #expect(action.cliName == "accounts github-connect")
        #expect(action.waitsForResult)
    }

    @Test(arguments: ["http://github.com/apps/cmux/installations/new", "https://example.test/apps/cmux/installations/new", "https://github.com@evil.test/apps/cmux/installations/new", "https://github.com/login", "https://github.com:443/apps/cmux/installations/new"])
    func onlyGitHubAppInstallationURLsOpen(_ url: String) {
        #expect(GitHubConnections.installationURL(url) == nil)
    }

    /// integration.connect answers one of three GitHub pages (cmux-api github-connect.ts): the App's
    /// installation page, its page for one owner, and GitHub's OAuth authorize page for an
    /// installation that already covers the owner. Each opens; nothing else on or off github.com does.
    @Test(arguments: [
        "https://github.com/apps/cmux/installations/new?state=s",
        "https://github.com/apps/cmux-test/installations/new/permissions?target_id=4242&state=s",
        "https://github.com/login/oauth/authorize?client_id=Iv1.abc&state=s&redirect_uri=https%3A%2F%2Fcmux.com%2Fintegrations%2Fcallback",
    ])
    func theThreeConnectPagesOpen(_ url: String) {
        #expect(GitHubConnections.installationURL(url)?.absoluteString == url)
    }

    @Test(arguments: [
        "http://github.com/login/oauth/authorize", "https://github.com.evil.test/login/oauth/authorize",
        "https://user@github.com/login/oauth/authorize", "https://github.com:8443/apps/cmux/installations/new/permissions",
        "https://github.com/apps/cmux/installations/new/permissions/more", "https://github.com/login/oauth/access_token",
        "https://github.com/login/oauth/authorize/../../evil", "https://github.com/settings/installations/42", "javascript:alert(1)",
    ])
    func otherPagesNeverOpen(_ url: String) {
        #expect(GitHubConnections.installationURL(url) == nil)
    }

    /// A chat's Connect GitHub card names the failed call's repository and the chat's link. The API
    /// decides what covers the repository, so an active connection elsewhere does not end it early;
    /// `connected: true` is done (nothing opens, no error), and the list is read again.
    @Test func aCardsConnectAsksForItsRepositoryAndAnsweredConnectedOpensNothing() async {
        var asked: [JSONValue] = []
        var operations: [String] = []
        var opened: [URL] = []
        let active: JSONValue = ["connections": [["id": "c1", "provider": "github", "status": "active", "created_by": "user"]],
                                 "providers": [["provider": "github", "configured": true]]]
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, params, _ in
            operations.append(op)
            if op == "integration.connect" {
                asked.append(params)
                return ["connection": ["id": "c1"], "connected": true]
            }
            return active
        }, open: { opened.append($0) })
        await model.connect(repo: "acme/web", returnTo: "cmux://session/ses-01")
        #expect(asked == [["provider": "github", "repo": "acme/web", "return_to": "cmux://session/ses-01"]])
        #expect(operations == ["integration.list", "integration.connect", "integration.list"])
        #expect(opened.isEmpty)
        #expect(!model.error)
        #expect(model.connected)
        // Without a repository (Settings, the palette, the CLI) an active connection is done as before.
        await model.connect()
        #expect(asked.count == 1)
    }

    /// A card for a repository GitHub must add opens the page the API answered (here the owner's
    /// installation page) and keeps that ask's own key: another repository asks again.
    @Test func eachRepositoryAsksWithItsOwnKey() async {
        var keys: [String?] = []
        var opened: [URL] = []
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, params, key in
            if op == "integration.connect" {
                keys.append(key)
                return ["connection": ["id": "p-\(params["repo"]?.stringValue ?? "")"],
                        "authorize_url": "https://github.com/apps/cmux/installations/new/permissions?target_id=9001&state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"]
            }
            return self.listing
        }, open: { opened.append($0) })
        await model.connect(repo: "acme/web", returnTo: nil)
        await model.connect(repo: "acme/api", returnTo: nil)
        #expect(opened.count == 2)
        #expect(keys.count == 2)
        #expect(keys[0] != nil && keys[0] != keys[1])
    }

    @Test func backendTeamUsesTheExistingIdentityContract() {
        #expect(GitHubConnections.backendTeam(project: "project", stackTeam: "team") == "team_3051e6705a6a35841b74")
        #expect(GitHubConnections.backendTeam(project: "project", stackTeam: nil) == nil)
    }
}

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

    @Test func aRefusedCompletionIsSaidWhereConnectIsAndClearedByTheNextConnect() async {
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, _, _ in
            op == "integration.connect" ? ["connection": ["id": "sample"], "authorize_url": "https://github.com/apps/cmux/installations/new?state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"] : self.listing
        }, open: { _ in })
        await model.perform("githubRefresh")
        model.linkRefusal = "The link expired; connect again."
        #expect(model.pageState["detail"]?.stringValue == "The link expired; connect again.")
        #expect(model.pageState["outcome"] == "failed")
        #expect(model.pageState["canConnect"] == true)
        await model.perform("githubConnect")
        #expect(model.linkRefusal == nil)
        #expect(model.pageState["detail"]?.stringValue != "The link expired; connect again.")
    }

    @Test func aSuspendedOrErroredConnectionHasItsOwnWordsNotConnectAgain() async {
        let rows: JSONValue = ["connections": [["id": "a", "provider": "github", "status": "needs_reauth"], ["id": "b", "provider": "github", "status": "error"], ["id": "c", "provider": "github", "status": "pending"]],
                               "providers": [["provider": "github", "configured": true]]]
        let model = GitHubConnections(scope: { self.scope }, call: { _, _, _, _ in rows }, open: { _ in })
        await model.perform("githubRefresh")
        let statuses = model.pageState["connections"]?.arrayValue?.compactMap { $0["status"]?.stringValue } ?? []
        #expect(statuses.count == 3)
        #expect(Set(statuses).count == 3, "needs_reauth, error and pending each read differently")
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

    /// #46018: Settings' Connect asks GitHub's redirect to come back to this app, which finishes it with its sign-in.
    @Test func connectAsksForTheAppsCompletionLinkWhenSet() async {
        var asked: [JSONValue] = []
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, params, _ in
            if op == "integration.connect" {
                asked.append(params)
                return ["connection": ["id": "sample"], "authorize_url": "https://github.com/apps/cmux/installations/new?state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"]
            }
            return self.listing
        }, open: { _ in })
        model.completionLink = "cmux-dev-x://integration/complete"
        await model.perform("githubRefresh")
        await model.perform("githubConnect")
        #expect(asked == [["provider": "github", "return_to": "cmux-dev-x://integration/complete"]])
    }

    /// An API from before the completion link refuses `return_to`: the connect asks again without it, under a derived key
    /// (the API keeps the first key; the same key with other params is an `idempotency.conflict`).
    @Test func anAPIThatRefusesTheCompletionLinkStillConnects() async {
        var asked: [(JSONValue, String?)] = []
        var opened: [URL] = []
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, params, key in
            if op == "integration.connect" {
                asked.append((params, key))
                if params["return_to"] != nil { throw GitHubConnections.GitHubFailure.refused }
                return ["connection": ["id": "sample"], "authorize_url": "https://github.com/apps/cmux/installations/new?state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"]
            }
            return self.listing
        }, open: { opened.append($0) })
        model.completionLink = "cmux-dev-x://integration/complete"
        await model.perform("githubRefresh")
        await model.perform("githubConnect")
        #expect(asked.map(\.0) == [["provider": "github", "return_to": "cmux-dev-x://integration/complete"], ["provider": "github"]])
        #expect(asked[0].1 != nil && asked[1].1 == asked[0].1.map { $0 + ":plain" })
        #expect(opened.count == 1)
        #expect(!model.error)
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

    /// #46018: Settings' Reconfigure opens an active connection's installation page on GitHub (any active one the
    /// person sees, shared ones too), never a pending one, and shows on the page for active rows only.
    @Test func reconfigureOpensTheActiveConnectionsInstallationPage() async {
        var operations: [String] = []
        var opened: [URL] = []
        var asked: [GitHubConnections.Scope] = []
        let page = URL(string: "https://github.com/settings/installations/42")!
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, _, _ in
            operations.append(op)
            return ["connections": [
                ["id": "shared", "provider": "github", "created_by": "another-user", "status": "active"],
                ["id": "waiting", "provider": "github", "created_by": "user", "status": "pending"],
            ], "providers": [["provider": "github", "configured": true]]]
        }, open: { opened.append($0) })
        model.reconfigurePage = { scope in asked.append(scope); return page }
        await model.perform("githubRefresh")
        let rows = model.pageState["connections"]?.arrayValue ?? []
        #expect(rows.map { $0["canReconfigure"] } == [.bool(true), .bool(false)])
        #expect(model.pageState["reconfigure"]?.stringValue == "Reconfigure")
        await model.perform("githubReconfigure", connection: "waiting")
        #expect(opened.isEmpty)
        await model.perform("githubReconfigure", connection: "shared")
        #expect(opened == [page])
        #expect(asked == [self.scope])
        #expect(operations == ["integration.list", "integration.list"])
        #expect(!model.error)
    }

    /// The API's `personalTeamIdFor` (sha256 "personal:<user>", 20 hex): Reconfigure with no Stack team asks the
    /// status route in this team, the one `integration.list` with no `x-cmux-team` reads.
    @Test func personalTeamMatchesTheAPIsId() {
        #expect(GitHubConnections.personalTeam(user: "user_0123456789abcdef0123") == "team_f06c7d72f5d3594f25d7")
    }

    @Test func reconfigureWithNoKnownPageSaysItFailed() async {
        var opened: [URL] = []
        let model = GitHubConnections(scope: { self.scope }, call: { _, _, _, _ in
            ["connections": [["id": "mine", "provider": "github", "created_by": "user", "status": "active"]],
             "providers": [["provider": "github", "configured": true]]]
        }, open: { opened.append($0) })
        model.reconfigurePage = { _ in nil }
        await model.perform("githubRefresh")
        await model.perform("githubReconfigure", connection: "mine")
        #expect(opened.isEmpty)
        #expect(model.error)
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
        #expect(model.canConnect, "a pending flow never blocks Connect; the held key resumes it")
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

    /// #46018: a pending connection this launch can't resume (another launch's, or one whose return to cmux failed) can't
    /// be finished, so it never makes Connect a no-op: Connect asks for a new one and opens GitHub, once per click.
    @Test func aPendingConnectionFromAnotherLaunchStillConnects() async {
        var connects = 0
        var opened = 0
        let model = GitHubConnections(scope: { self.scope }, call: { _, op, _, _ in
            if op == "integration.connect" {
                connects += 1
                return ["connection": ["id": "fresh"], "authorize_url": "https://github.com/apps/cmux/installations/new?state=a.eyJleHAiOjQxMDI0NDQ4MDB9.b"]
            }
            return ["connections": [["id": "stale", "provider": "github", "created_by": "user", "status": "pending"]], "providers": [["provider": "github", "configured": true]]]
        }, open: { _ in opened += 1 })
        await model.perform("githubRefresh")
        #expect(model.pageState["canConnect"] == true)
        await model.connect()
        #expect(connects == 1)
        #expect(opened == 1)
        // A second click reopens this launch's own page; it asks no second connection.
        await model.perform("githubConnect")
        #expect(connects == 1)
        #expect(opened == 2)
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

    @Test func backendTeamUsesTheExistingIdentityContract() {
        #expect(GitHubConnections.backendTeam(project: "project", stackTeam: "team") == "team_3051e6705a6a35841b74")
        #expect(GitHubConnections.backendTeam(project: "project", stackTeam: nil) == nil)
    }
}

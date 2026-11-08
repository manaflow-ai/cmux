import CmuxNextAccounts
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Settings > Accounts > Team agent keys: the team's shared Claude and Codex keys (Cloud multiplayer, lane E).
@MainActor
@Suite struct TeamAgentKeysTests {
    private let scope = TeamAgentKeys.Scope(user: "user", team: "team-acme")
    private let secret = "sk-test-0123456789abcd"

    private func status(manage: Bool, claude: JSONValue? = nil) -> JSONValue {
        let unset: (String) -> JSONValue = { ["agent": .string($0), "set": false, "kind": .null, "generation": 0, "updated_at": .null, "updated_by": .null, "hint": .null] }
        return ["team": "team_x", "can_manage": .bool(manage), "agents": [claude ?? unset("claude"), unset("codex")]]
    }

    private var claudeSet: JSONValue {
        ["agent": "claude", "set": true, "kind": "api_key", "generation": 1, "updated_at": 1_793_000_000_000, "updated_by": "user", "hint": "abcd"]
    }

    @Test func signedOutNeverCallsTheAPI() async {
        var calls = 0
        let model = TeamAgentKeys(scope: { nil }, call: { _, _, _, _ in calls += 1; return self.status(manage: true) })
        await model.refresh()
        await model.save(agent: "claude", kind: "api_key", secret: secret)
        await model.remove(agent: "claude")
        #expect(calls == 0)
        #expect(model.pageState["signIn"]?.stringValue?.isEmpty == false)
        #expect(model.pageState["agents"] == .array([]))
    }

    @Test func aPersonalTeamHasNothingToShareAndNeverCalls() async {
        var calls = 0
        let model = TeamAgentKeys(scope: { .init(user: "user", team: nil) }, call: { _, _, _, _ in calls += 1; return self.status(manage: true) })
        await model.refresh()
        await model.save(agent: "claude", kind: "api_key", secret: secret)
        #expect(calls == 0)
        #expect(model.pageState["note"]?.stringValue?.isEmpty == false)
        #expect(model.pageState["signIn"] == .null)
        #expect(model.pageState["agents"] == .array([]))
    }

    @Test func statusLoadsEveryAgentWithItsHint() async throws {
        var reads: [(String, JSONValue, String?)] = []
        let model = TeamAgentKeys(scope: { self.scope }, call: { _, op, params, key in
            reads.append((op, params, key))
            return self.status(manage: true, claude: self.claudeSet)
        })
        await model.refresh()
        try #require(reads.count == 1)
        #expect(reads[0].0 == "team.agent_key.status")
        #expect(reads[0].1 == [:])
        #expect(reads[0].2 == nil, "a read carries no mutation key")
        let agents = try #require(model.pageState["agents"]?.arrayValue)
        #expect(agents.map { $0["agent"] } == ["claude", "codex"])
        #expect(agents[0]["set"] == true)
        #expect(agents[0]["detail"]?.stringValue?.contains("abcd") == true)
        #expect(agents[1]["set"] == false)
        #expect(model.pageState["canManage"] == true)
    }

    @Test func saveSendsTheExactParamsAndRefreshes() async throws {
        var ops: [(String, JSONValue, String?)] = []
        var saved = false
        let model = TeamAgentKeys(scope: { self.scope }, call: { _, op, params, key in
            ops.append((op, params, key))
            if op == "team.agent_key.set" { saved = true; return self.claudeSet }
            return self.status(manage: true, claude: saved ? self.claudeSet : nil)
        })
        await model.refresh()
        // A paste usually carries a trailing newline; the API refuses surrounding whitespace.
        await model.save(agent: "claude", kind: "api_key", secret: secret + "\n")
        try #require(ops.count == 3)
        #expect(ops[1].0 == "team.agent_key.set")
        #expect(ops[1].1 == ["agent": "claude", "kind": "api_key", "secret": .string(secret)])
        #expect(ops[1].2?.isEmpty == false)
        #expect(ops[2].0 == "team.agent_key.status")
        #expect(model.pageState["agents"]?.arrayValue?.first?["set"] == true)
        #expect(model.pageState["agents"]?.arrayValue?.first?["notice"]?.stringValue?.isEmpty == false)
    }

    @Test func aMemberCannotSaveOrRemove() async {
        var mutations = 0
        let model = TeamAgentKeys(scope: { self.scope }, call: { _, op, _, _ in
            if op != "team.agent_key.status" { mutations += 1 }
            return self.status(manage: false, claude: self.claudeSet)
        })
        await model.refresh()
        await model.save(agent: "claude", kind: "api_key", secret: secret)
        await model.remove(agent: "claude")
        #expect(mutations == 0)
        #expect(model.pageState["canManage"] == false)
        #expect(model.pageState["note"]?.stringValue?.isEmpty == false, "members read that their admin manages the keys")
    }

    @Test func anInvalidPasteNeverCalls() async {
        var mutations = 0
        let model = TeamAgentKeys(scope: { self.scope }, call: { _, op, _, _ in
            if op != "team.agent_key.status" { mutations += 1 }
            return self.status(manage: true)
        })
        await model.refresh()
        await model.save(agent: "claude", kind: "api_key", secret: "short")
        await model.save(agent: "claude", kind: "api_key", secret: "has a space in it")
        await model.save(agent: "claude", kind: "password", secret: secret)
        await model.save(agent: "gemini", kind: "api_key", secret: secret)
        #expect(mutations == 0)
        #expect(model.pageState["agents"]?.arrayValue?.first?["error"]?.stringValue?.isEmpty == false)
    }

    @Test func aReplyForTheOldTeamNeverLandsInTheNewOne() async {
        var current: TeamAgentKeys.Scope? = scope
        let model = TeamAgentKeys(scope: { current }, call: { _, _, _, _ in
            current = .init(user: "user", team: "team-other")
            return self.status(manage: true, claude: self.claudeSet)
        })
        await model.refresh()
        #expect(model.pageState["agents"] == .array([]))
        #expect(model.pageState["canManage"] == false)
        #expect(model.pageState["busy"] == false)
    }

    @Test(arguments: [
        ("revision.conflict", "Another admin changed this key; try again."),
        ("auth.forbidden", "Only team owners and admins can change team keys."),
        ("validation.invalid", "This key is not valid. Paste the whole key or sign-in file again."),
        ("team_agent_key.not_configured", "Team keys are not available on this Cloud service yet."),
        ("owner.unreachable", "The Cloud service could not be reached. Try again."),
    ])
    func eachRefusalHasItsCopy(_ code: String, _ copy: String) async {
        let model = TeamAgentKeys(scope: { self.scope }, call: { _, op, _, _ in
            if op == "team.agent_key.set" { throw TeamAgentKeys.Failure.refused(code) }
            return self.status(manage: true)
        })
        await model.refresh()
        await model.save(agent: "claude", kind: "api_key", secret: secret)
        #expect(model.pageState["agents"]?.arrayValue?.first?["error"]?.stringValue == copy)
    }

    @Test func theSecretNeverReachesPageState() async {
        let model = TeamAgentKeys(scope: { self.scope }, call: { _, op, _, _ in
            if op == "team.agent_key.set" { throw URLError(.networkConnectionLost) }
            return self.status(manage: true)
        })
        await model.refresh()
        await model.save(agent: "claude", kind: "api_key", secret: secret)
        #expect(!model.pageState.compactText.contains(secret))
        #expect(!model.pageState.compactText.contains(String(secret.dropLast(4))))
        #expect(!String(describing: model).contains(secret))
    }

    @Test func aLostSaveReplaysItsKeyOnlyForTheSamePaste() async throws {
        var keys: [String] = []
        let model = TeamAgentKeys(scope: { self.scope }, call: { _, op, _, key in
            if op == "team.agent_key.set" {
                keys.append(try #require(key))
                if keys.count <= 2 { throw URLError(.networkConnectionLost) }
                return self.claudeSet
            }
            return self.status(manage: true)
        })
        await model.refresh()
        await model.save(agent: "claude", kind: "api_key", secret: secret)
        await model.save(agent: "claude", kind: "api_key", secret: secret)
        // A different key under the same idempotency key would be answered with the first one.
        await model.save(agent: "claude", kind: "api_key", secret: secret + "X")
        try #require(keys.count == 3)
        #expect(keys[0] == keys[1])
        #expect(keys[1] != keys[2])
    }

    @Test func aDefinitiveRefusalDropsTheKey() async throws {
        var keys: [String] = []
        let model = TeamAgentKeys(scope: { self.scope }, call: { _, op, _, key in
            if op == "team.agent_key.set" {
                keys.append(try #require(key))
                if keys.count == 1 { throw TeamAgentKeys.Failure.refused("revision.conflict") }
                return self.claudeSet
            }
            return self.status(manage: true)
        })
        await model.refresh()
        await model.save(agent: "claude", kind: "api_key", secret: secret)
        await model.save(agent: "claude", kind: "api_key", secret: secret)
        try #require(keys.count == 2)
        #expect(keys[0] != keys[1])
        #expect(model.pageState["agents"]?.arrayValue?.first?["error"] == .null)
    }

    @Test func removeSendsTheAgentAndRefreshes() async throws {
        var ops: [(String, JSONValue, String?)] = []
        var removed = false
        let model = TeamAgentKeys(scope: { self.scope }, call: { _, op, params, key in
            ops.append((op, params, key))
            if op == "team.agent_key.remove" { removed = true; return ["agent": "claude", "removed": true] }
            return self.status(manage: true, claude: removed ? nil : self.claudeSet)
        })
        await model.refresh()
        await model.remove(agent: "claude")
        try #require(ops.count == 3)
        #expect(ops[1].0 == "team.agent_key.remove")
        #expect(ops[1].1 == ["agent": "claude"])
        #expect(ops[1].2?.isEmpty == false)
        #expect(model.pageState["agents"]?.arrayValue?.first?["set"] == false)
    }

    @Test func theAccountsPageRoutesTheGesturesAndShowsTheCard() async throws {
        var ops: [String] = []
        let keys = TeamAgentKeys(scope: { self.scope }, call: { _, op, _, _ in
            ops.append(op)
            return op == "team.agent_key.set" ? self.claudeSet : self.status(manage: true)
        })
        let github = GitHubConnections(scope: { nil }, call: { _, _, _, _ in [:] }, open: { _ in })
        let accounts = AccountsModel(services: MockAccountsServices())
        _ = try await github.runAccountsPage(["action": "agentKeyRefresh"], accounts: accounts, agentKeys: keys)
        _ = try await github.runAccountsPage(["action": "agentKeySave", "provider": "codex", "name": "oauth", "secret": .string(secret)], accounts: accounts, agentKeys: keys)
        _ = try await github.runAccountsPage(["action": "agentKeyRemove", "provider": "codex"], accounts: accounts, agentKeys: keys)
        #expect(ops == ["team.agent_key.status", "team.agent_key.set", "team.agent_key.status"], "nothing set for Codex: remove sends nothing")
        let state = github.accountsPageState(accounts, agentKeys: keys)
        #expect(state["agentKeys"]?["title"]?.stringValue?.isEmpty == false)
        #expect(!state.compactText.contains(secret))
        await #expect(throws: (any Error).self) { try await github.runAccountsPage(["action": "agentKeyLeak"], accounts: accounts, agentKeys: keys) }
    }

    @Test func theOwnerAPIAnswerKeepsItsErrorCode() throws {
        let refusal = Data(#"{"ok":false,"error":{"code":"revision.conflict","message":"m","retryable":true}}"#.utf8)
        #expect(throws: TeamAgentKeys.Failure.refused("revision.conflict")) { try TeamAgentKeys.reply(status: 200, body: refusal) }
        #expect(throws: TeamAgentKeys.Failure.refused("owner.unreachable")) { try TeamAgentKeys.reply(status: 503, body: refusal) }
        #expect(throws: TeamAgentKeys.Failure.refused("auth.forbidden")) { try TeamAgentKeys.reply(status: 403, body: Data()) }
        let value = try TeamAgentKeys.reply(status: 200, body: Data(#"{"ok":true,"value":{"agent":"claude","removed":true}}"#.utf8))
        #expect(value["removed"] == true)
    }
}

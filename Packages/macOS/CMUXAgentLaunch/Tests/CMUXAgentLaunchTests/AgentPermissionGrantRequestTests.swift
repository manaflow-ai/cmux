import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Agent permission grant requests")
struct AgentPermissionGrantRequestTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grant-request-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test(arguments: [
        ("90", 90.0), ("45s", 45), ("30m", 1800), ("2h", 7200), ("7D", 604_800), (" 1h ", 3600),
    ])
    func durationsParse(text: String, seconds: TimeInterval) {
        #expect(AgentPermissionGrant.durationSeconds(from: text) == seconds)
    }

    @Test(arguments: ["", "h", "0", "-5m", "1.5h", "2w", "１h", "99999999999999999999"])
    func invalidDurationsAreRejected(text: String) {
        #expect(AgentPermissionGrant.durationSeconds(from: text) == nil)
    }

    @Test func sessionProposalKeepsOrderDropsDuplicatesAndFlagsBroadRules() throws {
        let proposal = try AgentPermissionGrantProposal.parse(params: [
            "rules": [" Bash(git:*) ", "Bash(*)", "Bash(git:*)", "Edit(~/Projects/app/**)"],
            "scope": "session",
            "session_id": "abc",
            "reason": "  run the release  ",
        ]).get()
        #expect(proposal.rules.map(\.rule) == ["Bash(git:*)", "Bash(*)", "Edit(~/Projects/app/**)"])
        #expect(proposal.rules.map(\.isBroad) == [true, true, false])
        #expect(proposal.defaultSelection == ["Edit(~/Projects/app/**)"])
        #expect(proposal.scope == .session(id: "abc"))
        #expect(proposal.reason == "run the release")
        #expect(proposal.expiresIn == AgentPermissionGrant.defaultDurationSeconds)
    }

    @Test func approvingASubsetCreatesAnExpiringGrantInRequestOrder() throws {
        let proposal = try AgentPermissionGrantProposal.parse(params: [
            "rules": ["Bash(git:*)", "Bash(gh:*)", "Bash(*)"],
            "scope": "session",
            "session_id": "abc",
            "expires_in_seconds": 7200,
        ]).get()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let grant = try #require(proposal.grant(approving: ["Bash(gh:*)", "Bash(git:*)", "Bash(unrequested:*)"], now: now))
        #expect(grant.rules == ["Bash(git:*)", "Bash(gh:*)"])
        #expect(grant.expiresAt == now.addingTimeInterval(7200))
        #expect(grant.scope == .session(id: "abc"))
        #expect(proposal.grant(approving: [], now: now) == nil)
        #expect(proposal.grant(approving: ["Bash(unrequested:*)"], now: now) == nil)
    }

    @Test func projectRootIsCanonicalizedAndMustBeAnExistingDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let proposal = try AgentPermissionGrantProposal.parse(params: [
            "rules": ["Bash(git:*)"], "scope": "project", "root": directory.path + "/./",
        ]).get()
        #expect(proposal.scope == .project(root: directory.resolvingSymlinksInPath().path))

        let file = directory.appendingPathComponent("file")
        try Data().write(to: file)
        for root in ["relative/dir", "/", file.path, directory.appendingPathComponent("missing").path] {
            #expect(AgentPermissionGrantProposal.parse(params: [
                "rules": ["Bash(git:*)"], "scope": "project", "root": root,
            ]) == .failure(.invalidProjectRoot), "\(root)")
        }
    }

    @Test func invalidRequestsAreRejected() {
        typealias Proposal = AgentPermissionGrantProposal
        let session: [String: Any] = ["scope": "session", "session_id": "abc"]
        func parse(_ extra: [String: Any]) -> Result<Proposal, Proposal.ValidationError> {
            Proposal.parse(params: session.merging(extra) { _, new in new })
        }
        #expect(parse([:]) == .failure(.missingRules))
        #expect(parse(["rules": []]) == .failure(.missingRules))
        #expect(parse(["rules": ["Bash(git:*"]]) == .failure(.invalidRule("Bash(git:*")))
        #expect(parse(["rules": ["Bash(git:*)\nBash(*)"]]) == .failure(.invalidRule("Bash(git:*)\nBash(*)")))
        #expect(parse(["rules": [7]]) == .failure(.invalidRule("7")))
        #expect(parse(["rules": (0...Proposal.maximumRuleCount).map { "Bash(tool\($0):*)" }]) == .failure(.tooManyRules))
        #expect(parse(["rules": ["Bash(git:*)"], "scope": "group"]) == .failure(.invalidScope))
        #expect(parse(["rules": ["Bash(git:*)"], "session_id": " "]) == .failure(.missingSessionID))
        #expect(parse(["rules": ["Bash(git:*)"], "expires_in_seconds": 5]) == .failure(.invalidExpiry))
        #expect(parse(["rules": ["Bash(git:*)"], "expires_in_seconds": 31 * 86_400]) == .failure(.invalidExpiry))
        #expect(parse(["rules": ["Bash(git:*)"], "reason": String(repeating: "x", count: 900)])
            .map { $0.reason?.count } == .success(Proposal.maximumReasonLength))
    }

    @Test func listPayloadCarriesScopeAndUseCount() {
        let now = Date(timeIntervalSince1970: 0)
        let id = UUID()
        let grant = AgentPermissionGrant(
            id: id, rules: ["Bash(git:*)"], scope: .project(root: "/repo"), reason: "ship",
            grantedAt: now, expiresAt: now.addingTimeInterval(60), useCount: 3
        )
        let payload = grant.socketPayload
        #expect(payload["id"] as? String == id.uuidString)
        #expect(payload["scope"] as? String == "project")
        #expect(payload["root"] as? String == "/repo")
        #expect(payload["use_count"] as? Int == 3)
        #expect(payload["granted_at"] as? String == "1970-01-01T00:00:00Z")
        #expect(payload["expires_at"] as? String == "1970-01-01T00:01:00Z")
        #expect(payload["last_used_at"] == nil)
        #expect(payload["session_id"] == nil)
    }
}

@Suite("Agent permission hook auto-answer")
struct AgentPermissionClaudeHookTests {
    private func payload(_ tool: String, _ input: [String: Any], session: String = "s1") -> [String: Any] {
        ["hook_event_name": "PermissionRequest", "session_id": session, "cwd": "/tmp",
         "tool_name": tool, "tool_input": input, "permission_suggestions": [["type": "addRules"]]]
    }

    @Test func matchParamsCarryOnlyMatchableFields() throws {
        let params = try #require(AgentPermissionRequest.claudeMatchParams(hookPayload: payload(
            "Edit", ["file_path": "/tmp/a", "old_string": "secret", "new_string": "x"]
        )))
        #expect(params["tool_name"] as? String == "Edit")
        #expect(params["session_id"] as? String == "s1")
        #expect(params["cwd"] as? String == "/tmp")
        #expect((params["tool_input"] as? [String: Any])?.keys.sorted() == ["file_path"])
        #expect(params["permission_suggestions"] == nil)
        #expect(AgentPermissionRequest.claudeMatchParams(hookPayload: payload("ExitPlanMode", ["plan": "x"])) == nil)
        #expect(AgentPermissionRequest.claudeMatchParams(hookPayload: payload("AskUserQuestion", [:])) == nil)
        #expect(AgentPermissionRequest.claudeMatchParams(hookPayload: ["tool_input": [:]]) == nil)
    }

    @Test func appAnswersMatchingRequestsAndCountsThem() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grant-hook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = AgentPermissionGrantRegistry(
            store: AgentPermissionGrantStore(fileURL: directory.appendingPathComponent("grants.json"))
        )
        let now = Date(timeIntervalSince1970: 1_000_000)
        func answer(_ payload: [String: Any]) throws -> Bool {
            let params = try #require(AgentPermissionRequest.claudeMatchParams(hookPayload: payload))
            return registry.answer(matchParams: params, now: now)
        }

        #expect(try !answer(payload("Bash", ["command": "git status"])), "No grants yet")
        let grant = AgentPermissionGrant(rules: ["Bash(git status)"], scope: .session(id: "s1"),
                                         grantedAt: now, expiresAt: now.addingTimeInterval(60))
        try registry.add(grant, now: now)

        #expect(try answer(payload("Bash", ["command": "git status"])))
        #expect(registry.activeGrants(now: now).first?.useCount == 1)
        #expect(try !answer(payload("Bash", ["command": "git status && rm -rf /"])))
        #expect(try !answer(payload("Bash", ["command": "git status"], session: "s2")))
        // A caller skipping matchParams still can't have questions answered.
        #expect(!registry.answer(matchParams: payload("ExitPlanMode", ["plan": "x"]), now: now))
        #expect(registry.activeGrants(now: now).first?.useCount == 1)

        let output = try #require(AgentPermissionRequest.claudeHookOutput(forMatchResult: ["allow": true]))
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let specific = try #require(decoded["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect((specific["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        #expect(AgentPermissionRequest.claudeHookOutput(forMatchResult: ["allow": false]) == nil)
        #expect(AgentPermissionRequest.claudeHookOutput(forMatchResult: [:]) == nil)
    }
}

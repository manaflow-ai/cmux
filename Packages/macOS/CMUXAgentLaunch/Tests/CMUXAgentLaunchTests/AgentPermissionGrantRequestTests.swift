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
        #expect(AgentPermissionGrantDuration.seconds(from: text) == seconds)
    }

    @Test(arguments: ["", "h", "0", "-5m", "1.5h", "2w", "１h", "99999999999999999999"])
    func invalidDurationsAreRejected(text: String) {
        #expect(AgentPermissionGrantDuration.seconds(from: text) == nil)
    }

    @Test func sessionProposalKeepsOrderDropsDuplicatesAndFlagsBroadRules() throws {
        let proposal = try AgentPermissionGrantProposal.parse(params: [
            "rules": [" Bash(git:*) ", "Bash(*)", "Bash(git:*)", "Edit(~/Projects/app/**)"],
            "scope": "session",
            "session_id": "abc",
            "reason": "  run the release  ",
        ]).get()
        #expect(proposal.rules.map(\.rule) == ["Bash(git:*)", "Bash(*)", "Edit(~/Projects/app/**)"])
        #expect(proposal.rules.map(\.isBroad) == [false, true, false])
        #expect(proposal.defaultSelection == ["Bash(git:*)", "Edit(~/Projects/app/**)"])
        #expect(proposal.scope == .session(id: "abc"))
        #expect(proposal.reason == "run the release")
        #expect(proposal.expiresIn == AgentPermissionGrantDuration.defaultSeconds)
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
struct AgentPermissionHookAutoAnswerTests {
    @Test func matchingRequestIsAllowedAndCounted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grant-hook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentPermissionGrantStore(fileURL: directory.appendingPathComponent("grants.json"))
        let now = Date(timeIntervalSince1970: 1_000_000)
        func payload(_ tool: String, _ input: [String: Any], session: String = "s1") -> [String: Any] {
            ["hook_event_name": "PermissionRequest", "session_id": session, "cwd": "/tmp",
             "tool_name": tool, "tool_input": input]
        }

        #expect(AgentPermissionHookAutoAnswer.answerClaudePermissionRequest(
            payload: payload("Bash", ["command": "git status"]), store: store, now: now
        ) == nil, "A missing store means no grants")

        let grant = AgentPermissionGrant(rules: ["Bash(git:*)", "ExitPlanMode", "AskUserQuestion"],
                                         scope: .session(id: "s1"), grantedAt: now, expiresAt: nil)
        try store.add(grant, now: now)

        let output = try #require(AgentPermissionHookAutoAnswer.answerClaudePermissionRequest(
            payload: payload("Bash", ["command": "git status"]), store: store, now: now
        ))
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let specific = try #require(decoded["hookSpecificOutput"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect((specific["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        #expect(store.grants(now: now).first?.useCount == 1)
        #expect(store.grants(now: now).first?.lastUsedAt == now)

        for unanswered in [
            payload("Bash", ["command": "git status && rm -rf /"]),
            payload("Bash", ["command": "git status"], session: "s2"),
            payload("ExitPlanMode", ["plan": "x"]),
            payload("AskUserQuestion", ["questions": []]),
        ] {
            #expect(AgentPermissionHookAutoAnswer.answerClaudePermissionRequest(
                payload: unanswered, store: store, now: now
            ) == nil)
        }
        #expect(store.grants(now: now).first?.useCount == 1)
    }
}

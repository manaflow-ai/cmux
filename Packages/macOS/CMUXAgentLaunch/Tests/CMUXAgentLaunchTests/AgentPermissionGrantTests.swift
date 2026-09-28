import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Agent permission rule matcher")
struct AgentPermissionRuleMatcherTests {
    private func bash(_ command: String) -> AgentPermissionRequest {
        AgentPermissionRequest(toolName: "Bash", command: command, cwd: "/tmp")
    }

    @Test func shellPrefixRulesMatchOnlySingleSimpleCommands() {
        #expect(AgentPermissionRuleMatcher.allows(rule: "Bash(git:*)", request: bash("git status")))
        #expect(AgentPermissionRuleMatcher.allows(rule: "Bash(git:*)", request: bash("git")))
        #expect(AgentPermissionRuleMatcher.allows(rule: "Bash(gh pr view *)", request: bash("gh pr view 12 --json state")))
        #expect(!AgentPermissionRuleMatcher.allows(rule: "Bash(git:*)", request: bash("gitk")))
        #expect(!AgentPermissionRuleMatcher.allows(rule: "Bash(gh pr view *)", request: bash("gh pr merge 12")))
        for chained in ["git status; rm -rf ~", "git log && curl x", "git log | sh", "git $(whoami)",
                        "git `id`", "git log > out", "git log &", "git log\nrm x", "git log \\\n; rm"] {
            #expect(!AgentPermissionRuleMatcher.allows(rule: "Bash(git:*)", request: bash(chained)), "\(chained)")
        }
        #expect(AgentPermissionRuleMatcher.allows(rule: "Bash(make test)", request: bash("make test")))
        #expect(!AgentPermissionRuleMatcher.allows(rule: "Bash(make test)", request: bash("make test-all")))
        #expect(!AgentPermissionRuleMatcher.allows(rule: "Bash(git:*)", request: AgentPermissionRequest(toolName: "Read")))
    }

    @Test func pathRulesMatchCanonicalAbsolutePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rule = "Edit(/\(root.path)/**)"
        func edit(_ path: String, tool: String = "Edit") -> AgentPermissionRequest {
            AgentPermissionRequest(toolName: tool, filePath: path, cwd: root.path)
        }
        #expect(AgentPermissionRuleMatcher.allows(rule: rule, request: edit(root.appendingPathComponent("src/a.swift").path)))
        #expect(AgentPermissionRuleMatcher.allows(rule: rule, request: edit(root.appendingPathComponent("new/b.swift").path, tool: "Write")))
        #expect(AgentPermissionRuleMatcher.allows(rule: rule, request: edit("src/relative.swift")))
        #expect(!AgentPermissionRuleMatcher.allows(rule: rule, request: edit(root.appendingPathComponent("../escape.swift").path)))
        #expect(!AgentPermissionRuleMatcher.allows(rule: rule, request: edit(root.path + "-sibling/x")))
        #expect(!AgentPermissionRuleMatcher.allows(rule: rule, request: edit(root.appendingPathComponent("src/a.swift").path, tool: "Bash")))
        // Relative rule paths depend on Claude's settings-file location; never matched.
        #expect(!AgentPermissionRuleMatcher.allows(rule: "Edit(src/**)", request: edit("src/a.swift")))
    }

    @Test func otherRuleForms() {
        let fetch = AgentPermissionRequest(toolName: "WebFetch", url: "https://api.github.com/repos")
        #expect(AgentPermissionRuleMatcher.allows(rule: "WebFetch(domain:github.com)", request: fetch))
        #expect(!AgentPermissionRuleMatcher.allows(rule: "WebFetch(domain:hub.com)", request: fetch))
        #expect(AgentPermissionRuleMatcher.allows(rule: "mcp__cmux", request: AgentPermissionRequest(toolName: "mcp__cmux__notify")))
        #expect(!AgentPermissionRuleMatcher.allows(rule: "mcp__cmux", request: AgentPermissionRequest(toolName: "mcp__cmuxx__notify")))
        #expect(AgentPermissionRuleMatcher.allows(rule: "WebSearch", request: AgentPermissionRequest(toolName: "WebSearch")))
        #expect(!AgentPermissionRuleMatcher.allows(rule: "Bash(git:*", request: AgentPermissionRequest(toolName: "Bash", command: "git")))
    }

    @Test func broadRulesAreFlagged() {
        #expect(AgentPermissionRuleMatcher.isBroad("Bash"))
        #expect(AgentPermissionRuleMatcher.isBroad("Bash(*)"))
        #expect(AgentPermissionRuleMatcher.isBroad("Bash(sudo:*)"))
        #expect(AgentPermissionRuleMatcher.isBroad("Edit(//**)"))
        #expect(AgentPermissionRuleMatcher.isBroad("Edit(~/**)"))
        #expect(AgentPermissionRuleMatcher.isBroad("WebFetch"))
        #expect(!AgentPermissionRuleMatcher.isBroad("Bash(git status)"))
        #expect(!AgentPermissionRuleMatcher.isBroad("Edit(~/Projects/app/**)"))
    }

    @Test func requestFromClaudeHookPayload() throws {
        let request = try #require(AgentPermissionRequest(claudeHookPayload: [
            "tool_name": "Bash",
            "tool_input": ["command": "git status"],
            "cwd": "/repo",
        ]))
        #expect(request == AgentPermissionRequest(toolName: "Bash", command: "git status", cwd: "/repo"))
        #expect(AgentPermissionRequest(claudeHookPayload: ["tool_input": [:]]) == nil)
    }
}

@Suite("Agent permission grant registry")
struct AgentPermissionGrantRegistryTests {
    private func makeStore() -> (AgentPermissionGrantStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("grant-store-\(UUID().uuidString)", isDirectory: true)
        return (AgentPermissionGrantStore(fileURL: directory.appendingPathComponent("grants.json")), directory)
    }

    @Test func matchesByScopeRecordsUseAndDropsExpired() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let registry = AgentPermissionGrantRegistry(store: store, now: now)
        let project = AgentPermissionGrant(rules: ["Bash(git status)"], scope: .project(root: directory.path),
                                           grantedAt: now, expiresAt: now.addingTimeInterval(3600))
        let session = AgentPermissionGrant(rules: ["Bash(make test)"], scope: .session(id: "s1"),
                                           grantedAt: now, expiresAt: now.addingTimeInterval(3600))
        let expired = AgentPermissionGrant(rules: ["Bash(ls:*)"], scope: .session(id: "s1"),
                                           grantedAt: now, expiresAt: now.addingTimeInterval(-1))
        try registry.add(project, now: now)
        try registry.add(session, now: now)
        try registry.add(expired, now: now.addingTimeInterval(-10))

        let inProject = AgentPermissionRequest(toolName: "Bash", command: "git status",
                                               cwd: directory.appendingPathComponent("sub").path)
        #expect(registry.answer(inProject, sessionID: "other", now: now))
        let outside = AgentPermissionRequest(toolName: "Bash", command: "git status", cwd: "/")
        #expect(!registry.answer(outside, sessionID: "other", now: now))
        let make = AgentPermissionRequest(toolName: "Bash", command: "make test", cwd: "/")
        #expect(registry.answer(make, sessionID: "s1", now: now))
        #expect(!registry.answer(make, sessionID: "s2", now: now))
        let ls = AgentPermissionRequest(toolName: "Bash", command: "ls", cwd: "/")
        #expect(!registry.answer(ls, sessionID: "s1", now: now), "Expired grants never match")
        #expect(!registry.answer(inProject, sessionID: nil, now: now.addingTimeInterval(7200)))
        #expect(registry.answer(inProject, sessionID: nil, now: now))

        let recorded = try #require(registry.activeGrants(now: now).first { $0.id == project.id })
        #expect(recorded.useCount == 2)
        #expect(recorded.lastUsedAt == now)
        #expect(registry.activeGrants(now: now).count == 2)

        // Use counts persist, and a new registry reloads them from disk.
        let reloaded = AgentPermissionGrantRegistry(store: store, now: now)
        #expect(reloaded.activeGrants(now: now).first { $0.id == project.id }?.useCount == 2)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        #expect(try registry.revoke(id: session.id, now: now) == 1)
        #expect(try registry.revoke(id: nil, now: now) == 1)
        #expect(registry.activeGrants(now: now).isEmpty)
        #expect(store.grants(now: now).isEmpty)
    }

    @Test func editingTheFileWhileRunningGrantsNothing() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let registry = AgentPermissionGrantRegistry(store: store, now: now)
        try store.save([AgentPermissionGrant(rules: ["Bash(make test)"], scope: .session(id: "s1"),
                                             grantedAt: now, expiresAt: now.addingTimeInterval(60))])
        let make = AgentPermissionRequest(toolName: "Bash", command: "make test", cwd: "/")
        #expect(!registry.answer(make, sessionID: "s1", now: now))
    }

    @Test func oneApprovalAtATime() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = AgentPermissionGrantRegistry(store: store)
        #expect(registry.beginApproval())
        #expect(!registry.beginApproval())
        registry.endApproval()
        #expect(registry.beginApproval())
    }
}

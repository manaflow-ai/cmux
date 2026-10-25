import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct ClaudeAccountSwitchPlannerTests {
    private let home = "/Users/u"

    private var reg: ClaudeAccountRegistry {
        ClaudeAccountRegistry(declarations: [.init(name: "work", configDir: "~/.claude-work")], homeDirectory: home)
    }

    private func plan(
        sessionID: String? = "s1",
        workingDirectory: String? = "/p",
        launchEnvironment: [String: String]? = nil,
        targetName: String
    ) -> Result<ClaudeAccountSwitchPlan, ClaudeAccountSwitchRefusal> {
        ClaudeAccountSwitchPlanner.plan(
            sessionID: sessionID, workingDirectory: workingDirectory, launchEnvironment: launchEnvironment,
            targetName: targetName, registry: reg, homeDirectory: home
        )
    }

    @Test func defaultToWork() throws {
        let p = try plan(launchEnvironment: ["FOO": "1"], targetName: "work").get()
        #expect(p.sourceConfigDirectory == "/Users/u/.claude")
        #expect(p.targetConfigDirectory == "/Users/u/.claude-work")
        #expect(p.surfaceEnvironmentOverrides == ["CLAUDE_CONFIG_DIR": "/Users/u/.claude-work", "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""])
        #expect(p.launchEnvironment == ["FOO": "1", "CLAUDE_CONFIG_DIR": "/Users/u/.claude-work"])
    }

    /// A restore replays only these keys, so every plan must stay within them.
    @Test func planTouchesExactlyTheAccountEnvironmentKeys() throws {
        for target in ["work", "default"] {
            let p = try plan(launchEnvironment: ["CLAUDE_CONFIG_DIR": "/Users/u/.other"], targetName: target).get()
            #expect(Set(p.surfaceEnvironmentOverrides.keys) == ClaudeAccountSwitchPlanner.accountEnvironmentKeys)
        }
    }

    @Test func workToDefaultClearsAccountKeys() throws {
        let p = try plan(
            launchEnvironment: ["CLAUDE_CONFIG_DIR": "/Users/u/.claude-work", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/x"],
            targetName: "default"
        ).get()
        #expect(p.surfaceEnvironmentOverrides == ["CLAUDE_CONFIG_DIR": "", "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""])
        #expect(p.launchEnvironment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(p.launchEnvironment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
        #expect(p.targetConfigDirectory == "/Users/u/.claude")
    }

    @Test func planFromUnregisteredSourceAccount() throws {
        let p = try plan(launchEnvironment: ["CLAUDE_CONFIG_DIR": "/Users/u/.claude-old"], targetName: "work").get()
        #expect(p.source.isRegistered == false)
        #expect(p.sourceConfigDirectory == "/Users/u/.claude-old")
    }

    @Test func refusals() {
        #expect(plan(sessionID: nil, targetName: "work") == .failure(.noClaudeSession))
        #expect(plan(sessionID: "", targetName: "work") == .failure(.noClaudeSession))
        #expect(plan(workingDirectory: nil, targetName: "work") == .failure(.missingWorkingDirectory))
        #expect(plan(workingDirectory: "", targetName: "work") == .failure(.missingWorkingDirectory))
        #expect(plan(targetName: "nope") == .failure(.unknownAccount("nope")))
        #expect(plan(targetName: "default") == .failure(.sameAccount("default")))
        #expect(
            plan(launchEnvironment: ["CLAUDE_CONFIG_DIR": "/Users/u/.claude-work"], targetName: "work")
                == .failure(.sameAccount("work"))
        )
    }

    @Test func refusalPrecedence() {
        #expect(plan(sessionID: nil, workingDirectory: nil, targetName: "nope") == .failure(.noClaudeSession))
        #expect(plan(workingDirectory: nil, targetName: "nope") == .failure(.missingWorkingDirectory))
    }
}

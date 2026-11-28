import Testing
@testable import CMUXAgentLaunch

@Suite("Registered agent resume")
struct RegisteredAgentResumeKindTests {
    @Test("Registered built-in kinds expose their canonical templates")
    func canonicalTemplates() {
        #expect(RegisteredAgentResumeKind.pi.commandTemplate == "{{executable}} --session {{sessionId}}")
        #expect(RegisteredAgentResumeKind.omp.commandTemplate == "{{executable}} --session {{sessionId}}")
        #expect(RegisteredAgentResumeKind.campfire.commandTemplate == "{{executable}} --session {{sessionId}}")
        #expect(RegisteredAgentResumeKind.antigravity.commandTemplate == "{{executable}} --conversation {{sessionId}}")
        #expect(RegisteredAgentResumeKind.grok.commandTemplate == "{{executable}} -r {{sessionId}}")
        #expect(RegisteredAgentResumeKind.kimi.commandTemplate == "{{executable}} --resume {{sessionId}}")
    }

    @Test("Pi registry resume preserves safe launch options and replaces stale selectors")
    func piResumePreservesLaunchOptions() {
        #expect(
            AgentResumeArgv().registeredBuiltInKind(
                kind: .pi,
                sessionId: "new-session",
                executablePath: "/opt/homebrew/bin/pi",
                arguments: [
                    "/opt/homebrew/bin/pi",
                    "--session-dir", "/tmp/pi sessions",
                    "--model", "foo",
                    "--session", "old-session",
                    "--continue",
                ]
            ) == [
                "/opt/homebrew/bin/pi",
                "--session", "new-session",
                "--session-dir", "/tmp/pi sessions",
                "--model", "foo",
            ]
        )
    }

    @Test("OMP uses the same registry-owned sanitizer path")
    func ompResumePreservesLaunchOptions() {
        #expect(
            AgentResumeArgv().registeredBuiltInKind(
                kind: .omp,
                sessionId: "new-session",
                executablePath: "/usr/local/bin/omp",
                arguments: [
                    "/usr/local/bin/omp",
                    "--session-dir", "/tmp/omp sessions",
                    "--session", "old-session",
                ]
            ) == [
                "/usr/local/bin/omp",
                "--session", "new-session",
                "--session-dir", "/tmp/omp sessions",
            ]
        )
    }

    @Test("Each registered built-in kind uses its distinct resume selector")
    func remainingRegisteredKindsUseExpectedSelectors() {
        let resumeArgv = AgentResumeArgv()

        #expect(
            resumeArgv.registeredBuiltInKind(
                kind: .campfire,
                sessionId: "session-id",
                executablePath: nil,
                arguments: ["campfire"]
            ) == ["campfire", "--session", "session-id"]
        )
        #expect(
            resumeArgv.registeredBuiltInKind(
                kind: .antigravity,
                sessionId: "session-id",
                executablePath: nil,
                arguments: ["agy"]
            ) == ["agy", "--conversation", "session-id"]
        )
        #expect(
            resumeArgv.registeredBuiltInKind(
                kind: .grok,
                sessionId: "session-id",
                executablePath: nil,
                arguments: ["grok"]
            ) == ["grok", "-r", "session-id"]
        )
        #expect(
            resumeArgv.registeredBuiltInKind(
                kind: .kimi,
                sessionId: "session-id",
                executablePath: nil,
                arguments: ["kimi"]
            ) == ["kimi", "--resume", "session-id"]
        )
    }
}

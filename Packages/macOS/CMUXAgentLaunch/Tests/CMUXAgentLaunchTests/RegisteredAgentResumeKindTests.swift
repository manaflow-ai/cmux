import Testing
@testable import CMUXAgentLaunch

@Suite("Registered agent resume")
struct RegisteredAgentResumeKindTests {
    @Test("Canonical registry registrations resolve to their built-in kinds")
    func canonicalRegistrationsResolve() {
        for kind in RegisteredAgentResumeKind.allCases {
            #expect(
                RegisteredAgentResumeKind(
                    registrationID: kind.rawValue,
                    resumeCommand: kind.commandTemplate
                ) == kind
            )
        }
    }

    @Test("Customized and unknown registrations stay template-owned")
    func customRegistrationsDoNotResolve() {
        #expect(
            RegisteredAgentResumeKind(
                registrationID: "pi",
                resumeCommand: "custom-pi --session {{sessionId}}"
            ) == nil
        )
        #expect(
            RegisteredAgentResumeKind(
                registrationID: "custom-agent",
                resumeCommand: "{{executable}} --session {{sessionId}}"
            ) == nil
        )
    }

    @Test("Pi registry resume preserves safe launch options and replaces stale selectors")
    func piResumePreservesLaunchOptions() {
        #expect(
            AgentResumeArgv().registeredBuiltInKind(
                registrationID: "pi",
                resumeCommand: RegisteredAgentResumeKind.pi.commandTemplate,
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
                registrationID: "omp",
                resumeCommand: RegisteredAgentResumeKind.omp.commandTemplate,
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
}

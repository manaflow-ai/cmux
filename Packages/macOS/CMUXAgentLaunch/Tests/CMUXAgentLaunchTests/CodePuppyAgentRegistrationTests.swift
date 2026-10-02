import CMUXAgentLaunch
import Foundation
import Testing

@Suite("Code Puppy agent registration")
struct CodePuppyAgentRegistrationTests {
    @Test("native hook resume uses the shared argv builder and preserves model/agent")
    func nativeResume() {
        #expect(AgentResumeArgv().builtInKind(
            kind: "code-puppy", sessionId: "auto_session_20260501_120000",
            executablePath: "/venv/bin/code-puppy",
            arguments: ["/venv/bin/code-puppy", "--resume", "old", "--model", "best", "--agent", "betty"]
        ) == ["/venv/bin/code-puppy", "--resume", "auto_session_20260501_120000", "--model", "best", "--agent", "betty"])
        #expect(AgentResumeArgv().builtInKind(
            kind: "code-puppy", sessionId: "named-session", executablePath: nil, arguments: []
        ) == ["code-puppy", "--resume", "named-session"])
        #expect(AgentResumeArgv().builtInKind(
            kind: "code-puppy", sessionId: "codepuppy-session", executablePath: nil, arguments: []
        ) == nil)
    }

    @Test("Code Puppy XDG cache selection survives capture and restore")
    func cacheEnvironment() {
        let policy = AgentLaunchEnvironmentPolicy()
        #expect(policy.selectedEnvironment(
            from: ["XDG_CACHE_HOME": "/tmp/puppy-cache"], kind: "code-puppy"
        )["XDG_CACHE_HOME"] == "/tmp/puppy-cache")
        #expect(policy.selectedRestoreEnvironment(
            from: ["XDG_CACHE_HOME": "/tmp/puppy-cache"], kind: "code-puppy"
        )["XDG_CACHE_HOME"] == "/tmp/puppy-cache")
    }

    @Test("exposes the shared detection, hook, and resume contract")
    func standardContract() {
        let registration = CodePuppyAgentRegistration.standard

        #expect(registration.id == "code-puppy")
        #expect(registration.commandName == "code-puppy")
        #expect(registration.configAliases == ["code-puppy", "codePuppy", "code_puppy", "codepuppy", "pup"])
        #expect(registration.hookAliases == ["pup"])
        #expect(registration.directBasenames == ["code-puppy", "code_puppy"])
        #expect(registration.argumentNeedles == ["code-puppy", "code_puppy"])
        #expect(registration.lifecycleEvents.map(\.agentEvent) == [
            "SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd",
        ])
        #expect(registration.lifecycleEvents.map(\.cmuxSubcommand) == [
            "session-start", "prompt-submit", "stop", "notification", "session-end",
        ])
        #expect(registration.pidEnvironmentVariable == "CMUX_CODE_PUPPY_PID")
        #expect(registration.hookConfigDirectory == ".code_puppy")
        #expect(registration.hookConfigFile == "hooks.json")
        #expect(registration.nestedGroupMatcher == "*")
        #expect(registration.hookTimeoutMilliseconds == 5_000)
        #expect(registration.resumeOption == "--resume")
        #expect(registration.resumeCommand.contains("{{sessionId}}"))
        #expect(registration.sessionDirectory == "~/.code_puppy/autosaves")
    }
}

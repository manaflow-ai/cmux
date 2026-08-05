import CMUXAgentLaunch
import Testing

@Suite("Code Puppy agent registration")
struct CodePuppyAgentRegistrationTests {
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

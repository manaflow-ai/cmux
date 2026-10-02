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

    @Test("hook identities require durable autosaves and resolve legacy suffixes")
    func durableIdentity() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("puppy-identity-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let registration = CodePuppyAgentRegistration.standard
        let environment = ["XDG_CACHE_HOME": root.path]
        let directory = registration.autosaveDirectory(homeDirectory: "/unused", environment: environment)
        #expect(directory.path == root.appendingPathComponent("code_puppy/autosaves").path)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["auto_session_20260501_120000", "named-session"] {
            try Data().write(to: directory.appendingPathComponent(name + ".pkl"))
            #expect(registration.resumableHookSessionID(
                name, homeDirectory: "/unused", environment: environment, fileManager: fm
            ) == name)
        }
        #expect(registration.resumableHookSessionID(
            "20260501_120000", homeDirectory: "/unused", environment: environment, fileManager: fm
        ) == "auto_session_20260501_120000")
        for invalid in ["codepuppy-session", "11111111-2222-3333-4444-555555555555", "../named-session"] {
            #expect(registration.resumableHookSessionID(
                invalid, homeDirectory: "/unused", environment: environment, fileManager: fm
            ) == nil)
        }
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
            "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "Stop", "SubagentStop", "Notification", "SessionEnd",
        ])
        #expect(registration.lifecycleEvents.map(\.cmuxSubcommand) == [
            "session-start", "prompt-submit", "tool-start", "tool-end",
            "stop", "stop", "notification", "session-end",
        ])
        #expect(registration.feedEvents.isEmpty)
        for event in registration.lifecycleEvents {
            #expect(AgentHookDeliveryPolicy().supportsQueuedDelivery(
                agent: registration.id, subcommand: event.cmuxSubcommand
            ))
        }
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

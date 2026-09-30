import Foundation
import Testing
@testable import CMUXAgentLaunch

/// An agent an update relaunch cut off mid-task resumes with a prompt to continue it.
@Suite struct AgentResumeContinuationPromptTests {
    private static let prompt = "cmux restarted to install an update while you were working. Continue where you left off."
    private static let sessionID = "0198f073-0a5b-7000-8000-00000000b001"
    private static let ambientEnvironment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": "/Users/me"]

    private static let planner = AgentRestorePlanner(
        isExecutableFile: { path in
            ["/opt/homebrew/bin/codex", "/opt/homebrew/bin/opencode", "/opt/homebrew/bin/teamclaude"]
                .contains(path)
        },
        isReadableFile: { _ in true },
        externalLaunchers: AgentExternalLauncherRegistry(launchers: [
            AgentExternalLauncher(
                id: "teamclaude",
                kinds: ["claude"],
                argvExecutables: ["teamclaude"],
                resumeArgvPrefix: ["teamclaude", "run", "--"]
            ),
        ])
    )

    private static func request(
        kind: String,
        arguments: [String],
        externalLauncher: String? = nil,
        mode: AgentRestoreRequestMode = .resumeAgent,
        continuationPrompt: String? = prompt
    ) -> AgentRestoreRequest {
        AgentRestoreRequest(
            mode: mode,
            kind: kind,
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: "/tmp/cmux-continuation",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                externalLauncher: externalLauncher,
                executablePath: "/opt/homebrew/bin/\(kind)",
                arguments: arguments,
                workingDirectory: "/tmp/cmux-continuation"
            ),
            preparedArguments: nil,
            observedPermissionMode: nil,
            continuationPrompt: continuationPrompt
        )
    }

    private static func arguments(for request: AgentRestoreRequest) throws -> [String] {
        try #require(planner.invocation(for: request, ambientEnvironment: ambientEnvironment)).arguments
    }

    @Test func claudeTakesThePromptRightAfterTheResumedSession() throws {
        #expect(try Self.arguments(for: Self.request(kind: "claude", arguments: ["claude", "--model", "opus"])) == [
            "claude", "--resume", Self.sessionID, Self.prompt, "--model", "opus",
        ])
    }

    @Test func codexTakesThePromptAsTheResumePositional() throws {
        #expect(try Self.arguments(for: Self.request(kind: "codex", arguments: ["codex"])) == [
            "/opt/homebrew/bin/codex", "resume", Self.sessionID, Self.prompt,
            "-c", "check_for_update_on_startup=false",
        ])
    }

    @Test func opencodeTakesThePromptOption() throws {
        #expect(try Self.arguments(for: Self.request(kind: "opencode", arguments: ["opencode"])) == [
            "/opt/homebrew/bin/opencode", "--session", Self.sessionID, "--prompt", Self.prompt,
        ])
    }

    @Test func externalLauncherPassesThePromptToTheAgent() throws {
        let request = Self.request(kind: "claude", arguments: ["/opt/homebrew/bin/claude"], externalLauncher: "teamclaude")
        #expect(try Self.arguments(for: request) == [
            "teamclaude", "run", "--", "--resume", Self.sessionID, Self.prompt,
        ])
    }

    @Test func resumeWithoutAPromptIsUnchanged() throws {
        #expect(try Self.arguments(for: Self.request(kind: "claude", arguments: ["claude"], continuationPrompt: nil)) == [
            "claude", "--resume", Self.sessionID,
        ])
        #expect(try Self.arguments(for: Self.request(kind: "claude", arguments: ["claude"], continuationPrompt: "  ")) == [
            "claude", "--resume", Self.sessionID,
        ])
    }

    @Test func kindsWithoutAKnownPromptFormResumePlainly() throws {
        let arguments = try Self.arguments(for: Self.request(kind: "gemini", arguments: ["gemini"]))
        #expect(!arguments.contains(Self.prompt))
        #expect(arguments.contains(Self.sessionID))
    }

    @Test func forkIgnoresThePrompt() throws {
        let arguments = try Self.arguments(for: Self.request(kind: "claude", arguments: ["claude"], mode: .forkAgent))
        #expect(!arguments.contains(Self.prompt))
    }
}

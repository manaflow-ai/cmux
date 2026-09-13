import CMUXAgentLaunch
import Foundation
import Testing

@Suite struct ClaudeDefaultConfigDirectoryResumeTests {
    @Test(arguments: ["~/.claude", NSHomeDirectory() + "/.claude", NSHomeDirectory() + "/.claude/"])
    func captureOmitsDefaultConfigDirectory(configDirectory: String) {
        let environment = ["CLAUDE_CONFIG_DIR": configDirectory]
        let policy = AgentLaunchEnvironmentPolicy()

        #expect(policy.selectedEnvironment(from: environment, kind: "claude").isEmpty)
        #expect(policy.selectedRestoreEnvironment(from: environment, kind: "claude").isEmpty)
    }

    @Test(arguments: [AgentRestoreRequestMode.resumeAgent, .forkAgent])
    func persistedDefaultConfigDirectoryDoesNotChangeRestoredAuth(mode: AgentRestoreRequestMode) throws {
        let request = AgentRestoreRequest(
            mode: mode,
            kind: "claude",
            checkpointID: "a22293b7-bcef-4707-8439-2f538c8517a4",
            source: "session-snapshot",
            workingDirectory: "/tmp",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                arguments: ["claude"],
                environment: ["CLAUDE_CONFIG_DIR": NSHomeDirectory() + "/.claude"]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
        let invocation = try #require(AgentRestorePlanner(isExecutableFile: { _ in false }).invocation(
            for: request,
            ambientEnvironment: ["PATH": "/usr/bin:/bin"]
        ))

        #expect(invocation.arguments.contains("--resume"))
        #expect(invocation.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(invocation.environment["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV"] == nil)
        #expect(invocation.environment["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS"] == nil)
    }

    @Test func customConfigDirectoryKeepsItsAuthSelection() throws {
        let customDirectory = NSHomeDirectory() + "/.claude-work"
        let request = AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "claude",
            checkpointID: "a22293b7-bcef-4707-8439-2f538c8517a4",
            source: "session-snapshot",
            workingDirectory: "/tmp",
            environment: [:],
            launchCommand: AgentLaunchCommand(
                arguments: ["claude"],
                environment: ["CLAUDE_CONFIG_DIR": customDirectory]
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
        let invocation = try #require(AgentRestorePlanner(isExecutableFile: { _ in false }).invocation(
            for: request,
            ambientEnvironment: [:]
        ))

        #expect(invocation.environment["CLAUDE_CONFIG_DIR"] == customDirectory)
        #expect(invocation.environment["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV"] == "1")
        #expect(invocation.environment["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS"] == "CLAUDE_CONFIG_DIR")
    }
}

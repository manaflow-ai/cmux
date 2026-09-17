import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct CodexWriterRestorePlanningTests {
    @Test func verificationHomeIsAlsoTheAccountUsedByExec() throws {
        let session = UUID().uuidString
        let invocation = try #require(AgentRestorePlanner(isExecutableFile: { _ in false }).invocation(
            for: AgentRestoreRequest(
                mode: .resumeAgent, kind: "codex", checkpointID: session, source: "agent-hook",
                workingDirectory: "/project", environment: [:],
                launchCommand: AgentLaunchCommand(arguments: ["codex"], verificationHome: "/saved-user"),
                preparedArguments: nil, observedPermissionMode: nil
            ),
            ambientEnvironment: ["HOME": "/current-user", "CODEX_HOME": "/wrong-account"]
        ))
        #expect(invocation.environment["CODEX_HOME"] == "/saved-user/.codex")
        #expect(invocation.codexResumeSessionID == session)
    }

    @Test func legacyRemoteResumeNeedsNoLocalAccount() throws {
        let session = UUID().uuidString
        let command = try #require(CodexLegacyRestoreCommand(
            command: "codex --remote ws://remote.invalid resume \(session)", sessionID: session
        ))
        #expect(CodexWriterRestorePreflight().inspect(
            sessionID: session, arguments: command.arguments, environment: [:],
            workingDirectory: "/unused", fallbackHome: "/unused"
        ) == nil)
        #expect(CodexLegacyRestoreCommand(command: "codex resume \(session)", sessionID: session) == nil)
    }

    @Test func legacyParserRejectsExpansionAndDifferentThreads() {
        let session = UUID().uuidString
        #expect(CodexLegacyRestoreCommand(command: "env CODEX_HOME=$HOME/.codex codex resume \(session)", sessionID: session) == nil)
        #expect(CodexLegacyRestoreCommand(command: "env CODEX_HOME=/account codex resume \(UUID().uuidString)", sessionID: session) == nil)
        #expect(CodexLegacyRestoreCommand(command: "env CODEX_HOME=/account codex resume \(session); echo changed", sessionID: session) == nil)
    }
}

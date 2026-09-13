import CMUXAgentLaunch
import Foundation
import Testing

/// A captured Claude `--settings <path>` is only replayed when the file is still
/// readable on the restoring machine. subrouter's ephemeral
/// `$TMPDIR/subrouter-claude-settings-<rand>/settings.json` is the motivating
/// case: it exists at capture and is deleted when `sr` exits, and Claude
/// refuses to start on a missing settings file.
@Suite("Claude restore plans drop --settings paths that are gone")
struct ClaudeRestoreSettingsPathTests {
    private let sessionID = "3d1d5a5a-6d36-4d3a-9a3c-1d4f0e6c2b7a"
    private let deadPath = "/var/folders/zz/T/subrouter-claude-settings-3294281412/settings.json"
    private let livePath = "/home/me/settings.json"

    @Test("A resume plan keeps a readable --settings path in both spellings")
    func resumeKeepsReadableSettings() throws {
        let invocation = try #require(plan(
            mode: .resumeAgent,
            arguments: ["/opt/homebrew/bin/claude", "--settings", livePath, "--settings=\(livePath)", "--model", "opus"],
            readable: [livePath]
        ))
        #expect(invocation.arguments == [
            "claude", "--resume", sessionID, "--settings", livePath, "--settings=\(livePath)", "--model", "opus"
        ])
    }

    @Test("A resume plan drops an unreadable --settings path in both spellings")
    func resumeDropsUnreadableSettings() throws {
        let invocation = try #require(plan(
            mode: .resumeAgent,
            arguments: ["/opt/homebrew/bin/claude", "--settings", deadPath, "--settings=\(deadPath)", "--model", "opus"],
            readable: []
        ))
        #expect(invocation.arguments == ["claude", "--resume", sessionID, "--model", "opus"])
    }

    @Test("Only the dead path is dropped when a readable one is captured alongside it")
    func mixedSettingsKeepOnlyReadablePath() throws {
        let invocation = try #require(plan(
            mode: .resumeAgent,
            arguments: ["/opt/homebrew/bin/claude", "--settings", deadPath, "--settings", livePath],
            readable: [livePath]
        ))
        #expect(invocation.arguments == ["claude", "--resume", sessionID, "--settings", livePath])
    }

    @Test("Inline JSON --settings never consults the filesystem")
    func inlineSettingsAreNotFileChecked() throws {
        let inline = #"{"effortLevel":"max"}"#
        let invocation = try #require(plan(
            mode: .resumeAgent,
            arguments: ["/opt/homebrew/bin/claude", "--settings", inline, "--settings=\(inline)"],
            readable: []
        ))
        #expect(invocation.arguments == ["claude", "--resume", sessionID, "--settings", inline, "--settings=\(inline)"])
    }

    @Test("A tilde --settings path is checked after expansion")
    func tildeSettingsPathIsExpandedBeforeCheck() throws {
        let home = NSHomeDirectory()
        let invocation = try #require(plan(
            mode: .resumeAgent,
            arguments: ["/opt/homebrew/bin/claude", "--settings", "~/claude-settings.json"],
            readable: ["\(home)/claude-settings.json"]
        ))
        #expect(invocation.arguments == ["claude", "--resume", sessionID, "--settings", "~/claude-settings.json"])
    }

    @Test("A fork plan drops an unreadable --settings path too")
    func forkDropsUnreadableSettings() throws {
        let invocation = try #require(plan(
            mode: .forkAgent,
            arguments: ["/opt/homebrew/bin/claude", "--settings", deadPath, "--model", "opus"],
            readable: []
        ))
        #expect(!invocation.arguments.contains(deadPath))
        #expect(invocation.arguments.contains("--model"))
        #expect(invocation.arguments.contains("opus"))
    }

    @Test("A direct plan replays the recorded argv untouched")
    func directPlanIsNotFiltered() throws {
        let invocation = try #require(AgentRestorePlanner(
            isExecutableFile: { _ in false },
            isReadableFile: { _ in false }
        ).invocation(
            for: AgentRestoreRequest(
                mode: .direct,
                kind: "claude",
                checkpointID: sessionID,
                source: "session-snapshot",
                workingDirectory: nil,
                environment: [:],
                launchCommand: nil,
                preparedArguments: ["/opt/homebrew/bin/claude", "--settings", deadPath],
                observedPermissionMode: nil
            ),
            ambientEnvironment: [:]
        ))
        #expect(invocation.arguments == ["/opt/homebrew/bin/claude", "--settings", deadPath])
    }

    private func plan(
        mode: AgentRestoreRequestMode,
        arguments: [String],
        readable: Set<String>
    ) -> AgentRestoreInvocation? {
        AgentRestorePlanner(
            isExecutableFile: { _ in false },
            isReadableFile: { readable.contains($0) }
        ).invocation(
            for: AgentRestoreRequest(
                mode: mode,
                kind: "claude",
                checkpointID: sessionID,
                source: "agent-hook",
                workingDirectory: nil,
                environment: [:],
                launchCommand: AgentLaunchCommand(
                    executablePath: "/opt/homebrew/bin/claude",
                    arguments: arguments
                ),
                preparedArguments: nil,
                observedPermissionMode: nil
            ),
            ambientEnvironment: [:]
        )
    }
}

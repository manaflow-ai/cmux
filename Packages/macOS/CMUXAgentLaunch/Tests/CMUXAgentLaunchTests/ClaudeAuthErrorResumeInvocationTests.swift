import Foundation
import Testing
@testable import CMUXAgentLaunch

/// A Claude tab whose turn ended on "Not logged in" is resumed by typing
/// `cmux restore claude <id>` into its shell, which plans the relaunch from the
/// tab's restore record. The relaunch must keep the session id, working
/// directory, launch flags and account directory, inherit the login the
/// restoring shell has (`CLAUDE_CODE_OAUTH_TOKEN`), and honour the shell's
/// `CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV` opt-in exactly as a fresh launch
/// in the same shell would.
@Suite("Claude auth-error resume invocation")
struct ClaudeAuthErrorResumeInvocationTests {
    private let sessionID = "5c0ffee0-1d2e-4f00-9a00-00000000a001"
    private let capturedClaude = "/opt/homebrew/bin/claude"
    private let project = "/Users/me/Projects/cmux"
    private let configDirectory = "/Users/me/.claude-accounts/work"
    private let preserveKey = "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV"
    private let preserveKeysKey = "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS"

    private var planner: AgentRestorePlanner {
        AgentRestorePlanner(
            isExecutableFile: { $0 == "/shim/claude" },
            isReadableFile: { _ in true }
        )
    }

    private func request() -> AgentRestoreRequest {
        AgentRestoreRequest(
            mode: .resumeAgent,
            kind: "claude",
            checkpointID: sessionID,
            source: "agent-hook",
            workingDirectory: project,
            environment: [:],
            launchCommand: AgentLaunchCommand(
                launcher: nil,
                executablePath: capturedClaude,
                arguments: [capturedClaude, "--dangerously-skip-permissions", "--model", "opus"],
                workingDirectory: project,
                environment: ["CLAUDE_CONFIG_DIR": configDirectory],
                capturedAt: 1,
                source: "test"
            ),
            preparedArguments: nil,
            observedPermissionMode: nil
        )
    }

    private func ambient(_ extra: [String: String] = [:]) -> [String: String] {
        [
            "PATH": "/tmp/cmux-shims:/opt/homebrew/bin:/usr/bin:/bin",
            "CMUX_CLAUDE_WRAPPER_SHIM": "/shim/claude",
            "HOME": "/Users/me",
            "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-test-token",
            "ANTHROPIC_API_KEY": "sk-ant-api03-test-key",
        ].merging(extra) { _, extra in extra }
    }

    private func preservedKeys(_ invocation: AgentRestoreInvocation) -> Set<String> {
        Set(
            (invocation.environment[preserveKeysKey] ?? "")
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .map(String.init)
        )
    }

    @Test("Resume keeps the session id, cwd, launch flags, account and shell login")
    func resumeKeepsIdentityFlagsAndLogin() throws {
        let invocation = try #require(planner.invocation(for: request(), ambientEnvironment: ambient()))
        let arguments = invocation.arguments

        #expect(arguments.first == "/shim/claude", "\(arguments)")
        let resumeIndex = try #require(arguments.firstIndex(of: "--resume"), "\(arguments)")
        #expect(arguments.indices.contains(resumeIndex + 1))
        #expect(arguments[resumeIndex + 1] == sessionID, "\(arguments)")
        #expect(arguments.contains("--dangerously-skip-permissions"), "\(arguments)")
        let modelIndex = try #require(arguments.firstIndex(of: "--model"), "\(arguments)")
        #expect(arguments[modelIndex + 1] == "opus", "\(arguments)")
        #expect(!arguments.contains("/login"), "\(arguments)")
        #expect(!arguments.contains("sr"), "\(arguments)")

        #expect(invocation.workingDirectory == project)
        #expect(invocation.environment["CLAUDE_CONFIG_DIR"] == configDirectory)
        // The token is never persisted in the restore record; it reaches the
        // relaunch only through the restoring shell, and must not be dropped.
        #expect(invocation.environment["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-ant-oat01-test-token")
    }

    @Test("A shell-wide auth-selection opt-in survives the resume, as on a fresh launch")
    func blanketOptInIsNotNarrowedToTheRecordKeys() throws {
        let invocation = try #require(planner.invocation(
            for: request(),
            ambientEnvironment: ambient([preserveKey: "1"])
        ))

        #expect(invocation.environment[preserveKey] == "1")
        // An empty key list is the wrapper's "preserve every auth key" form. The
        // record's own CLAUDE_CONFIG_DIR list must not replace it, or the
        // wrapper strips ANTHROPIC_API_KEY only on the resumed launch.
        #expect(invocation.environment[preserveKeysKey] == nil)
        #expect(invocation.environment["ANTHROPIC_API_KEY"] == "sk-ant-api03-test-key")
    }

    @Test("A shell opt-in with named keys is merged with the record's keys")
    func namedOptInKeysAreMerged() throws {
        let invocation = try #require(planner.invocation(
            for: request(),
            ambientEnvironment: ambient([preserveKey: "1", preserveKeysKey: "ANTHROPIC_API_KEY"])
        ))

        #expect(invocation.environment[preserveKey] == "1")
        #expect(preservedKeys(invocation) == ["ANTHROPIC_API_KEY", "CLAUDE_CONFIG_DIR"])
    }

    @Test("Without a shell opt-in only the record's own auth selection is preserved")
    func noOptInPreservesOnlyRecordKeys() throws {
        let invocation = try #require(planner.invocation(for: request(), ambientEnvironment: ambient()))

        #expect(invocation.environment[preserveKey] == "1")
        #expect(preservedKeys(invocation) == ["CLAUDE_CONFIG_DIR"])
    }
}

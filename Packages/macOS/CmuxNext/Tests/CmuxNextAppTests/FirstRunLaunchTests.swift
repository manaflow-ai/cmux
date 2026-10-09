@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextOnboarding
import Foundation
import Testing

/// The first-run gate at launch (plans/cmux-next/onboarding.md 4, S1): the
/// Swift first-run window no longer opens; a launch with data ends the first
/// run silently with `reason: existing-data`; Claude/Codex history on disk is
/// detection input, not data.
@MainActor
@Suite struct FirstRunLaunchTests {
    private static func root() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "first-run-launch-\(UUID().uuidString)")
    }

    private static func onboarding(_ services: AppServices, root: URL) -> OnboardingService {
        OnboardingService(services: services, stateFile: OnboardingStateFile(url: root.appending(path: "onboarding.json")))
    }

    private static func userWorkspace() -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 2), key: WorkspaceKey(rawValue: "user"), name: "code")
    }

    @Test func aLaunchWithWorkspacesShowsNoWindowAndRecordsExistingData() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [Self.userWorkspace()]))
        let onboarding = Self.onboarding(services, root: root)
        let needed = FirstWorkspace.isNeeded(services.daemon.store.workspaces, leftover: [])
        let decision = await onboarding.decideFirstRun(FirstRunGate(firstWorkspaceNeeded: needed, agentSessions: 0, config: .absent, classicSnapshot: false))
        #expect(decision == .existingData(.workspaces))
        #expect(!onboarding.isShowing, "no onboarding window")
        let record = try #require(onboarding.state.file.record())
        #expect(record.isFinished)
        #expect(record.reason == "existing-data")
    }

    @Test func aFreshLaunchShowsNoSwiftWindowAndStaysUnfinished() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let services = ActionBindingCoverageTests.boundServices()
        let onboarding = Self.onboarding(services, root: root)
        let needed = FirstWorkspace.isNeeded(services.daemon.store.workspaces, leftover: [])
        let decision = await onboarding.decideFirstRun(FirstRunGate(firstWorkspaceNeeded: needed, agentSessions: 0, config: .absent, classicSnapshot: false))
        #expect(decision == .firstRun)
        #expect(onboarding.firstRunDecision == .firstRun)
        #expect(!onboarding.isShowing, "the first run is the New Tab page (S2), never the Swift window")
        let record = try #require(onboarding.state.file.record())
        #expect(!record.isFinished)
    }

    /// A new cmux user with Claude Code and Codex history is the main target:
    /// that history on disk counts for nothing in the gate.
    @Test func claudeAndCodexHistoryAloneIsAFirstRun() throws {
        let home = Self.root()
        defer { try? FileManager.default.removeItem(at: home) }
        let files = [".claude/projects/-Users-me-code/0001.jsonl", ".codex/sessions/2026/10/09/rollout-1.jsonl",
                     ".pi/agent/sessions/one.jsonl", ".local/share/opencode/storage/session/info/ses_1.json"]
        for file in files {
            let url = home.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"type":"user","cwd":"/Users/me/code"}"#.utf8).write(to: url)
        }
        let config = FirstRunGate.ConfigOrigin.beforeSeeding(home: home, environment: [:])
        #expect(config == .absent)
        let classic = ClassicSessionImporter(fileURL: home.appending(path: "Library/Application Support/cmux/session-com.cmuxterm.app.json"))
        #expect(!classic.hasSnapshot)
        let gate = FirstRunGate(firstWorkspaceNeeded: true, agentSessions: 0, config: config, classicSnapshot: classic.hasSnapshot)
        #expect(gate.decide(launch: .start) == .firstRun)
    }

    /// The config check reads the seed source before seeding, not whether the
    /// file exists afterwards.
    @Test func theConfigOriginReadsTheSeedSource() throws {
        let home = Self.root()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appending(path: ".config/cmux")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(FirstRunGate.ConfigOrigin.beforeSeeding(home: home, environment: [:]) == .absent)
        try Data(#"{"appearance": {"theme": "Dracula"}}"#.utf8).write(to: directory.appending(path: "cmux.json"))
        #expect(FirstRunGate.ConfigOrigin.beforeSeeding(home: home, environment: [:]) == .seededFromClassic)
        try Data("// mine\n{}\n".utf8).write(to: directory.appending(path: "cmux-next.json"))
        #expect(FirstRunGate.ConfigOrigin.beforeSeeding(home: home, environment: [:]) == .empty, "{} with comments is empty")
        try Data(#"{"terminal": {"fontSize": 14}}"#.utf8).write(to: directory.appending(path: "cmux-next.json"))
        #expect(FirstRunGate.ConfigOrigin.beforeSeeding(home: home, environment: [:]) == .settings)
        let override = home.appending(path: "override.json")
        #expect(FirstRunGate.ConfigOrigin.beforeSeeding(home: home, environment: ["CMUX_NEXT_CONFIG_FILE": override.path]) == .absent,
                "an override is never seeded from classic")
    }
}

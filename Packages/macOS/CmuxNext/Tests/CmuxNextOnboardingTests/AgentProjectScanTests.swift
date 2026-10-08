import Foundation
import Testing
@testable import CmuxNextOnboarding

/// The project scan over a fixture home: each agent's session layout, the
/// grouping by folder, the ranking, and what is left out.
@Suite struct AgentProjectScanTests {
    let home: URL
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let day: TimeInterval = 86_400

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "agent-scan-\(UUID().uuidString)", directoryHint: .isDirectory)
        for folder in ["code/app", "code/api", "code/old"] {
            try FileManager.default.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }
    }

    func folder(_ relative: String) -> String { home.appending(path: relative).standardizedFileURL.path }

    /// Writes JSON lines to `relative` under the home, last modified `age` days ago.
    func write(_ relative: String, _ records: [[String: Any]], age: Double) throws {
        let file = home.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now - age * day], ofItemAtPath: file.path)
    }

    @Test func findsEachAgentsSessionsAndGroupsThemByFolder() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let app = folder("code/app"), api = folder("code/api")
        try write(".claude/projects/-app/a.jsonl", [["type": "summary"], ["type": "user", "cwd": app]], age: 0)
        try write(".claude/projects/-app/b.jsonl", [["cwd": app]], age: 1)
        try write(".codex/sessions/2026/09/30/rollout-2026-09-30T10-00-00-x.jsonl",
                  [["type": "session_meta", "payload": ["id": "x", "cwd": app]]], age: 2)
        try write(".codex/sessions/2026/09/30/rollout-2026-09-30T11-00-00-y.jsonl",
                  [["type": "session_meta", "payload": ["id": "y", "cwd": api]]], age: 3)
        try write(".pi/agent/sessions/--api--/s.jsonl", [["type": "session", "id": "s", "cwd": api]], age: 4)
        try write(".local/share/opencode/storage/session/p1/ses.json", [["id": "ses", "directory": api]], age: 5)

        let projects = AgentProjectScan(home: home).run(now: now)
        #expect(projects.map(\.id) == [app, api])
        #expect(projects[0].sessions == 3 && projects[0].apps == [.claudeCode, .codex])
        #expect(projects[1].sessions == 3 && projects[1].apps == [.codex, .pi, .opencode])
        #expect(abs(projects[0].lastActive.timeIntervalSince(now)) < 1)
    }

    /// Left out: a folder that is gone, the home folder, a temporary folder,
    /// an agent's own folder. Kept unlooked-at: a folder on the Desktop.
    @Test func leavesOutWhatIsNotAProjectAndNeverLooksInsideGuardedFolders() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let records = [folder("code/gone"), home.path, "/tmp/scratch", folder(".claude/worktrees/x"), folder("Desktop/notes")]
        for (index, cwd) in records.enumerated() {
            try write(".claude/projects/p\(index)/s.jsonl", [["cwd": cwd]], age: 0)
        }
        let scan = AgentProjectScan(home: home)
        let projects = scan.run(now: now)
        #expect(projects.map(\.id) == [folder("Desktop/notes")])
        #expect(scan.privacyFolder(of: projects[0].folder) == .desktop)
        #expect(scan.privacyFolder(of: URL(fileURLWithPath: folder("Library/Mobile Documents/com~apple~CloudDocs/x"))) == .iCloudDrive)
        #expect(scan.privacyFolder(of: URL(fileURLWithPath: folder("code/app"))) == nil)
        #expect(scan.privacyFolder(of: URL(fileURLWithPath: folder("Desktopish/app"))) == nil)
        // The disk ignores case; other volumes and cloud storage providers prompt too.
        #expect(scan.privacyFolder(of: URL(fileURLWithPath: folder("desktop/notes"))) == .desktop)
        #expect(scan.privacyFolder(of: URL(fileURLWithPath: "/Volumes/work/app")) == .volumes)
        #expect(scan.privacyFolder(of: URL(fileURLWithPath: folder("Library/CloudStorage/Dropbox/app"))) == .cloudStorage)
    }

    /// Recency leads; many sessions lift a project only while it is recent.
    @Test func ranksByRecencyWeightedBySessionCount() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let app = folder("code/app"), api = folder("code/api"), old = folder("code/old")
        for index in 0..<40 { try write(".claude/projects/old/\(index).jsonl", [["cwd": old]], age: 90) }
        for index in 0..<2 { try write(".claude/projects/app/\(index).jsonl", [["cwd": app]], age: 1) }
        for index in 0..<10 { try write(".claude/projects/api/\(index).jsonl", [["cwd": api]], age: 3) }
        #expect(AgentProjectScan(home: home).run(now: now).map(\.id) == [api, app, old])
    }

    /// A first record longer than the 64 KB read still yields its cwd.
    @Test func aCutOffFirstRecordStillNamesItsFolder() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let app = folder("code/app")
        // Written by hand: Codex puts `cwd` ahead of its long instructions.
        let instructions = String(repeating: #"Say \"cwd\":\"/nope\" never. "#, count: 4000)
        let file = home.appending(path: ".codex/sessions/2026/09/30/rollout-2026-09-30T10-00-00-z.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = #"{"type":"session_meta","payload":{"id":"z","cwd":"\#(app)","base_instructions":{"text":"\#(instructions)"}}}"#
        try (record + "\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(try Data(contentsOf: file).count > 64 * 1024)
        #expect(AgentProjectScan.recordedCwd(.codex, file) == app)
        #expect(AgentProjectScan.cwdField(in: Data(#"{"a":1,"cwd":"/x/\"q\" y","b":"#.utf8)[...]) == #"/x/"q" y"#)
    }

    @Test func emptyWhenNoAgentHasRun() {
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(AgentProjectScan(home: home).run(now: now).isEmpty)
    }

    @Test func includesGitRepositoriesUnderProjectsRoots() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let repository = home.appending(path: "Projects/demo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"), withIntermediateDirectories: true)
        let projects = AgentProjectScan(home: home).run(now: now)
        #expect(projects.map(\.id) == [repository.standardizedFileURL.path])
        #expect(projects[0].sessions == 0)
    }

    @Test func liveHonorsTheAgentsOwnHomeVariables() {
        defer { try? FileManager.default.removeItem(at: home) }
        let scan = AgentProjectScan.live(environment: ["CLAUDE_CONFIG_DIR": "/cfg/claude", "CODEX_HOME": "/cfg/codex", "PI_CODING_AGENT_DIR": "",
                                                       "XDG_DATA_HOME": "/data"])
        #expect(scan.claude.path == "/cfg/claude" && scan.codex.path == "/cfg/codex")
        #expect(scan.pi.path.hasSuffix("/.pi/agent") && scan.opencode.path == "/data/opencode")
    }

    @Test func recentScanMergesAgentHintsAndBoundedGitRepositories() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let agent = folder("code/app")
        let hinted = folder("code/from-classic-history")
        let repo = folder("Projects/example")
        let nestedRepo = folder("Projects/group/nested")
        for path in [hinted, repo, nestedRepo] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        }
        try write(".claude/projects/-app/session.jsonl", [["cwd": agent]], age: 0)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: repo).appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: nestedRepo).appending(path: ".git"), withIntermediateDirectories: true)

        let scan = RecentProjectScan(projects: AgentProjectScan(home: home), roots: [home.appending(path: "Projects")], maxProjects: 20)
        let projects = scan.run(hints: [hinted], now: now)
        #expect(Set(projects.map(\.id)) == Set([agent, hinted, repo, nestedRepo]))
        #expect(Set(scan.complete(query: "Projects", hints: [hinted])) == Set([repo, nestedRepo]))
    }

    /// A folderless workspace's chats run in cmux's private agent-home folder
    /// (`<workspace-uuid>` under Application Support): never a project to pick.
    @Test func leavesOutCmuxAgentHomeFolders() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let app = folder("code/app")
        let chat = folder("Library/Application Support/cmux/agent-home/6b16a112-289d-4467-9675-8e6feee99481")
        let other = folder("Library/Application Support/cmux/agent-home/home")
        for path in [chat, other] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
        }
        try write(".claude/projects/-chat/s.jsonl", [["cwd": chat]], age: 0)
        try write(".claude/projects/-app/s.jsonl", [["cwd": app]], age: 1)
        let scan = RecentProjectScan(projects: AgentProjectScan(home: home), roots: [], maxProjects: 20)
        #expect(scan.run(hints: [other, chat], now: now).map(\.id) == [app])
        #expect(scan.complete(query: "", hints: [other, chat]) == [app])
    }

    @Test func recentScanKeepsPrivacyGuardedHintsWithoutReadingThem() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let desktop = folder("Desktop/hidden-project")
        let scan = RecentProjectScan(projects: AgentProjectScan(home: home), roots: [])
        let projects = scan.run(hints: [desktop], now: now)
        #expect(projects.map(\.id) == [desktop])
    }
}

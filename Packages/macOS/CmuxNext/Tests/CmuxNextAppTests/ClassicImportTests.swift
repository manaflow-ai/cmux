import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextOnboarding
import Foundation
import Testing

/// `workspace.importClassic` (cx-rwlb, cx-1uacm), end to end: the real daemon,
/// the app's actions, and real classic 0.64.19 session files
/// (tests/fixtures/classic-to-next):
/// - `session-com.cmuxterm.app.json`: a split workspace (shared with
///   classic-to-next.py's test).
/// - `session-everything.json`: a workspace with browser tabs and an SSH
///   workspace, both made through classic's own CLI. Two parts are added by
///   hand in classic's schema: the Claude Code session on the `claude`
///   terminal (`terminal.agent`) and the `vm box` Cloud VM workspace
///   (`cloudVM`). The capture mini had no credentials for either.
@MainActor @Suite(.serialized, .ownsSidebarDocStore, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClassicImportTests {
    private static func fixture(_ name: String) -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("tests/fixtures/classic-to-next/\(name)")
    }

    private static let splits = fixture("session-com.cmuxterm.app.json")
    private static let everything = fixture("session-everything.json")

    @Test func previewIncludesInterruptedWorkspacesThatWillBeReplaced() {
        let source = ClassicMigrationSource(
            path: "/tmp/session.json",
            bundleID: ClassicSessionImporter.stableBundleIdentifier,
            size: 1,
            modifiedAt: 1,
            createdAt: 1
        )
        let plan = ClassicImportPlan(
            source: source,
            migration: ClassicMigrationPlan(cleanup: ["half-made-1", "half-made-2"])
        )
        #expect(plan.cleanupWorkspaces == 2)
        #expect(ClassicImportStrings.previewLines(plan).count == 9)
    }

    /// What the import left: each workspace's pane trees by name, the SSH
    /// destinations it reached, and its toast.
    private struct Imported {
        var shapes: [String: [String]] = [:]
        var sshDestinations: [String] = []
        var notice: String?
        /// Screen text of each probed terminal (`<workspace>/<tab>`) after
        /// it printed its replay file.
        var probes: [String: String] = [:]
    }

    /// A tab as text: a terminal's name, `browser:<url>`, `chat:<harness>`.
    private static func label(_ tab: TabSnapshot) -> String {
        switch tab.kind {
        case .browser: "browser:\(tab.url ?? "")"
        case .conversation: "chat:\(tab.conversation?.agentSession?.harness ?? "")"
        default: tab.name ?? tab.title
        }
    }

    /// The pane tree as text: tab labels in a pane, `right(…|…)` / `down(…|…)` for a split.
    private static func shape(_ node: LayoutNode, _ panes: [PaneSnapshot]) -> String {
        switch node {
        case .leaf(let id):
            return (panes.first { $0.id == id }?.tabs ?? []).map(label).joined(separator: ",")
        case .split(_, _, let direction, _, let a, let b):
            return "\(direction.rawValue)(\(shape(a, panes))|\(shape(b, panes)))"
        default:
            return "?"
        }
    }

    /// The person runs Import Workspaces from Classic cmux: classic's split
    /// workspace opens with the same panes, tabs, tab names and directions.
    @Test func importKeepsTheClassicSplitWorkspace() async throws {
        let shapes = try await importClassic(Self.splits).shapes.values.flatMap { $0 }
        // Left: api and logs as tabs of one pane; right: web over db.
        #expect(shapes.contains("right(api,logs|down(web|db))"), "\(shapes)")
    }

    /// A pane holding only a panel the import cannot bring (here a markdown
    /// viewer) closes up instead of becoming a stray terminal.
    @Test func aPaneOfPanelsThatDoNotComeOverClosesUp() async throws {
        let db = "\"title\":\"db\",\"ttyName\":\"ttys023\",\"type\":\"terminal\""
        let shapes = try await importClassic(Self.splits) { session in
            #expect(session.contains(db), "the fixture's db panel changed")
            return session.replacingOccurrences(of: db, with: "\"title\":\"db\",\"type\":\"markdown\"")
        }.shapes.values.flatMap { $0 }
        #expect(shapes.contains("right(api,logs|web)"), "\(shapes)")
    }

    /// Browser tabs come over with their URLs, in their pane and order
    /// (classic: `new-pane --type browser`, then a second tab in that pane).
    @Test func browserTabsComeOverWithTheirURLs() async throws {
        let shapes = try await importClassic(Self.everything).shapes["full"] ?? []
        #expect(shapes.contains { $0.hasSuffix("|browser:https://example.com/docs,browser:https://example.org/)") }, "\(shapes)")
    }

    /// A terminal that ran a Claude Code session comes over as an agent chat
    /// resuming that session (acpmux adopt), where the terminal was.
    @Test func anAgentSessionComesOverAsItsChat() async throws {
        let shapes = try await importClassic(Self.everything).shapes["full"] ?? []
        #expect(shapes.contains { $0.hasPrefix("right(down(app|chat:claude)|") }, "\(shapes)")
    }

    /// Once the agent exits, classic drops `terminal.agent` and keeps only the
    /// session's `resumeBinding`; that session still comes over as its chat.
    @Test func anEndedAgentSessionComesOverAsItsChat() async throws {
        let shapes = try await importClassic(Self.everything) { Self.endingTheAgent($0, source: "agent-hook") }.shapes["full"] ?? []
        #expect(shapes.contains { $0.hasPrefix("right(down(app|chat:claude)|") }, "\(shapes)")
    }

    /// A binding classic did not get from the agent's own hook (here a session
    /// import's, which classic keeps for manual use only) names no session to
    /// resume: its terminal stays a terminal.
    @Test func aBindingNotFromTheAgentsHookStaysATerminal() async throws {
        let shapes = try await importClassic(Self.everything) { Self.endingTheAgent($0, source: "session-import") }.shapes["full"] ?? []
        #expect(shapes.contains { $0.hasPrefix("right(down(app|claude)|") }, "\(shapes)")
    }

    /// The fixture's Claude Code terminal as classic saves it after the agent
    /// exited: no `terminal.agent`, the session in a `resumeBinding` from `source`.
    private static func endingTheAgent(_ session: String, source: String) -> String {
        let agent = #"{"agent":{"kind":"claude","sessionId":"7f3c2a10-5b4e-4c8d-9a61-2e0f8b9d4c37","workingDirectory":"/Users/cmux/p4rt-full/proj/docs"},"#
        #expect(session.contains(agent), "the fixture's agent terminal changed")
        return session.replacingOccurrences(of: agent, with: #"{"resumeBinding":{"kind":"claude","checkpointId":"7f3c2a10-5b4e-4c8d-9a61-2e0f8b9d4c37","cwd":"/Users/cmux/p4rt-full/proj/docs","command":"claude --resume 7f3c2a10-5b4e-4c8d-9a61-2e0f8b9d4c37","source":"\#(source)","launchFlavor":{"kind":"local"},"autoResume":false},"wasAgentRunning":false,"#)
    }

    /// A folder classic saved that no longer exists on this Mac (a deleted
    /// project or a cleared /tmp) opens in the home folder; the workspace
    /// still comes over with its splits.
    @Test func aWorkspaceWhoseFolderIsGoneStillComesOver() async throws {
        let shapes = try await importClassic(Self.everything) { session in
            #expect(session.contains("/Users/cmux/p4rt-full/proj/app"), "the fixture's folders changed")
            return session.replacingOccurrences(of: "/Users/cmux/p4rt-full/proj/app", with: "/Users/cmux/p4rt-full/gone/app")
        }.shapes["full"] ?? []
        #expect(shapes.contains { $0.hasPrefix("right(down(app|chat:claude)|") }, "\(shapes)")
    }

    /// An SSH workspace opens on its host (classic: `cmux ssh cmux@127.0.0.1
    /// --port 2222`), through the daemon for that destination.
    @Test func anSSHWorkspaceOpensOnItsHost() async throws {
        let imported = try await importClassic(Self.everything)
        #expect(imported.sshDestinations == ["cmux@127.0.0.1:2222"], "\(imported.sshDestinations)")
        #expect(imported.shapes["ssh box"] != nil, "\(imported.shapes.keys.sorted())")
    }

    /// A Cloud VM workspace stays in classic, and the toast says so.
    @Test func aCloudVMWorkspaceStaysInClassicAndTheToastSaysSo() async throws {
        let imported = try await importClassic(Self.everything)
        #expect(imported.shapes["vm box"] == nil, "\(imported.shapes.keys.sorted())")
        #expect(imported.notice?.contains("Cloud VM") == true, "\(imported.notice ?? "no toast")")
    }

    /// Classic's older Cloud VMs were saved as a `remote` on the websocket
    /// transport with a `managedCloudVMID`, without `cloudVM`: they stay in
    /// classic too, and the import never tries SSH to them.
    @Test func anOlderCloudVMWorkspaceStaysInClassic() async throws {
        let imported = try await importClassic(Self.everything) { session in
            #expect(session.contains("\"transport\":\"ssh\""), "the fixture's SSH workspace changed")
            return session.replacingOccurrences(of: "\"transport\":\"ssh\"",
                                                with: "\"transport\":\"websocket\",\"managedCloudVMID\":\"vm-legacy1\"")
        }
        #expect(imported.sshDestinations.isEmpty, "\(imported.sshDestinations)")
        #expect(imported.shapes["ssh box"] == nil, "\(imported.shapes.keys.sorted())")
        #expect(imported.notice?.contains("Cloud VM") == true, "\(imported.notice ?? "no toast")")
    }

    /// Classic saved each terminal's scrollback (cx-gzh.1). A local terminal
    /// starts with it as a read-only replay file (`CMUX_RESTORE_SCROLLBACK_FILE`,
    /// printed above the first prompt by the shell layer); an SSH terminal's
    /// shell runs on its host, where this Mac's file is not, so its scrollback
    /// stays behind and the toast says so. The SSH workspace still opens.
    @Test func scrollbackComesBackAboveTheFirstPromptAndTheToastNamesWhatStayed() async throws {
        let imported = try await importClassic(Self.everything, probe: true) { session in
            let app = #""terminal":{"isRemoteTerminal":false,"workingDirectory":"/Users/cmux/p4rt-full/proj/app"}"#
            let ssh = #""terminal":{"isRemoteTerminal":true,"#
            #expect(session.contains(app) && session.contains(ssh), "the fixture's terminals changed")
            return session
                .replacingOccurrences(of: app, with: #""terminal":{"isRemoteTerminal":false,"scrollback":"$ make test\n\u001b[32mall 12 passed\u001b[0m\n","workingDirectory":"/Users/cmux/p4rt-full/proj/app"}"#)
                .replacingOccurrences(of: ssh, with: #""terminal":{"isRemoteTerminal":true,"scrollback":"remote build log\n","#)
        }
        #expect(imported.shapes["ssh box"] != nil, "\(imported.shapes.keys.sorted())")
        #expect(imported.probes["full/app"]?.contains("all 12 passed") == true, "\(imported.probes)")
        let remote = imported.probes.filter { $0.key.hasPrefix("ssh box/") }.values
        #expect(!remote.isEmpty && remote.allSatisfy { $0.contains("probe-42") && !$0.contains("remote build log") }, "\(imported.probes)")
        #expect(imported.notice?.contains("scrollback") == true, "\(imported.notice ?? "no toast")")
    }

    /// Every terminal of a split workspace gets its own scrollback: a later
    /// tab of a pane (`logs`) and each split's new pane (`web`, `db`), not
    /// only the workspace's first terminal.
    @Test func eachSplitTerminalGetsItsOwnScrollback() async throws {
        let imported = try await importClassic(Self.splits, probe: true) { session in
            var session = session
            for name in ["api/logs", "web", "db"] {
                let terminal = #""workingDirectory":"/Users/cmux/p4rt-classic/proj/"# + name + #""}"#
                #expect(session.contains(terminal), "the fixture's \(name) terminal changed")
                session = session.replacingOccurrences(
                    of: terminal, with: #""scrollback":"saved in "# + name + #"\n","workingDirectory":"/Users/cmux/p4rt-classic/proj/"# + name + #""}"#)
            }
            return session
        }
        for (tab, name) in [("logs", "api/logs"), ("web", "web"), ("db", "db")] {
            let screen = imported.probes["split api/\(tab)"] ?? ""
            #expect(screen.contains("saved in \(name)"), "\(tab): \(screen)")
            #expect(screen.components(separatedBy: "saved in ").count == 2, "\(tab) printed another terminal's scrollback: \(screen)")
        }
    }

    /// A session acpmux cannot resume as a chat (its plan is the harness's
    /// own terminal) stays a terminal in its folder, never a broken chat.
    @Test func anAgentSessionAcpmuxCannotResumeStaysATerminal() async throws {
        let shapes = try await importClassic(Self.everything, plan: { _, cwd in
            ["kind": "terminal", "terminal": ["argv": ["claude", "--resume", "7f3c2a10-5b4e-4c8d-9a61-2e0f8b9d4c37"]], "cwd": cwd ?? ""]
        }).shapes["full"] ?? []
        #expect(shapes.contains { $0.hasPrefix("right(down(app|claude)|") }, "\(shapes)")
    }

    /// The import's preview is a real gate: before the answer no saved
    /// workspace opens, and Cancel leaves every active restore path untouched.
    @Test func classicImportPreviewCancelRestoresNothing() async throws {
        let imported = try await importClassic(Self.everything, confirm: false)
        #expect(imported.shapes["full"] == nil, "\(imported.shapes)")
        #expect(imported.shapes["ssh box"] == nil, "\(imported.shapes)")
        #expect(imported.sshDestinations.isEmpty, "\(imported.sshDestinations)")
    }

    /// acpmux's answer for a session it can adopt.
    private nonisolated static func adoptPlan(_ adopt: AgentPaneAdopt, _ cwd: String?) -> [String: Any] {
        ["kind": "adopt", "adopt": ["harness": adopt.harness, "agentSessionId": adopt.agentSessionId],
         "sessionNew": [String: Any](), "cwd": cwd ?? ""]
    }

    /// Runs the action on `fixture` (after `edit`), with SSH workspaces
    /// reaching this test's daemon and acpmux answering `plan`, and returns
    /// what it opened.
    private func importClassic(_ fixture: URL, probe: Bool = false, confirm: Bool = true,
                               _ edit: (String) -> String = { $0 },
                               plan: @escaping (AgentPaneAdopt, String?) -> [String: Any] = ClassicImportTests.adoptPlan) async throws -> Imported {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-classic-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        // The fixtures' folders, moved under this test's scratch directory.
        let proj = root.appendingPathComponent("proj")
        for folder in ["api/logs", "web", "db", "app", "docs"] {
            try FileManager.default.createDirectory(at: proj.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // Classic writes `\/` in paths; plain `/` reads the same.
        let session = try edit(String(contentsOf: fixture, encoding: .utf8).replacingOccurrences(of: "\\/", with: "/"))
            .replacingOccurrences(of: "/Users/cmux/p4rt-classic/proj", with: proj.path)
            .replacingOccurrences(of: "/Users/cmux/p4rt-full/proj", with: proj.path)
            .replacingOccurrences(of: "/Users/cmux", with: root.path)
        let file = root.appendingPathComponent("session-com.cmuxterm.app.json")
        try session.write(to: file, atomically: true, encoding: .utf8)

        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-classic-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.onboarding.classicSessions = ClassicSessionImporter(fileURL: file)
        services.onboarding.classicMigrationDirectory = root.appendingPathComponent("migration")
        services.onboarding.classicMigrationDirectory = root.appendingPathComponent("migration")
        services.onboarding.classicMigrationAtLaunch = false
        var destinations: [String] = []
        services.onboarding.classicSSH = { destination in
            destinations.append(destination)
            return services.daemon
        }
        services.onboarding.classicChatPlan = { adopt, cwd in AcpmuxChatOpenPlan(result: plan(adopt, cwd)) }
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        defer {
            services.daemon.shutdownConnection()
            for controller in services.windows.controllers { controller.window?.close() }
        }
        // The daemon ends with its terminals on every path, a failed expectation included.
        let result: Result<Imported, any Error>
        do { result = .success(try await Self.importAndRead(services, probe: probe, confirm: confirm)) } catch { result = .failure(error) }
        // Stop the app's connection first: on the daemon's EOF it would start a
        // fresh daemon that outlives the test. The shutdown uses its own socket.
        if let connection = services.daemon.connection {
            services.daemon.shutdownConnection()
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
        var imported = try result.get()
        imported.sshDestinations = destinations
        return imported
    }

    /// Waits for the launch, runs the action and reads every workspace's
    /// pane trees and the toast; with `probe`, each terminal prints its
    /// replay file.
    private static func importAndRead(_ services: AppServices, probe: Bool, confirm: Bool) async throws -> Imported {
        let deadline = ContinuousClock.now + .seconds(90)
        // The launch is ready once restore has made its first terminal.
        func ready() -> Bool { services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } } }
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try #require(ready(), "the launch made no terminal")
        let connection = try #require(services.daemon.connection)
        let before = try await connection.listWorkspaces().workspaces.count
        defer { CmuxDialogCenter.shared.dismissAll() }

        var ran = false
        let work = services.registry.capturingWork { ran = services.registry.perform("workspace.importClassic") }
        #expect(ran, "workspace.importClassic is not an action")
        let previewDeadline = ContinuousClock.now + .seconds(5)
        while !CmuxDialogCenter.shared.records.contains(where: { $0.spec.identifier == "cmux.dialog.classicImport" }),
              ContinuousClock.now < previewDeadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let preview = try #require(CmuxDialogCenter.shared.records.last {
            $0.spec.identifier == "cmux.dialog.classicImport"
        }, "classic import showed no preview")
        #expect(preview.spec.title == ClassicImportStrings.previewTitle)
        #expect(preview.spec.lines.count == 9 && preview.spec.lines.allSatisfy { !$0.isEmpty })
        #expect(preview.spec.defaultButton?.id == ClassicImportConfirmation.importButton)
        #expect(preview.spec.cancelButton?.id == "cancel")
        #expect(try await connection.listWorkspaces().workspaces.count == before,
                "classic workspaces opened before confirmation")
        if confirm {
            #expect(CmuxDialogCenter.shared.press(preview.id, button: "import"))
        } else {
            #expect(CmuxDialogCenter.shared.key(.escape, in: preview.id))
        }
        for task in work { #expect(await task.value == nil) }

        var imported = Imported(notice: services.onboarding.classicImportNotice)
        for workspace in try await connection.listWorkspaces().workspaces {
            guard let screen = workspace.screens.first else { continue }
            let trees = [screen.layout] + screen.columns.flatMap { [$0.layout] + $0.rows.map(\.layout) }
            imported.shapes[workspace.name, default: []] += trees.map { shape($0, screen.panes) }
            guard probe else { continue }
            for tab in screen.panes.flatMap(\.tabs) where tab.kind != .browser && tab.kind != .conversation {
                imported.probes["\(workspace.name)/\(label(tab))"] = try await printReplay(tab.surface, connection)
            }
        }
        return imported
    }

    /// The test shell (`/bin/sh`) has no replay hook: print the replay file
    /// by hand and read the screen once the shell is done with it.
    private static func printReplay(_ surface: SurfaceID, _ connection: DaemonConnection) async throws -> String {
        try await connection.send(surface, text: "cat \"${CMUX_RESTORE_SCROLLBACK_FILE:-/dev/null}\"; echo probe-$((40+2))\r")
        let deadline = ContinuousClock.now + .seconds(10)
        var text = ""
        while ContinuousClock.now < deadline {
            text = try await connection.request(ReadScreenRequest(surface: surface), timeout: .seconds(5)).text
            if text.contains("probe-42") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return text
    }
}

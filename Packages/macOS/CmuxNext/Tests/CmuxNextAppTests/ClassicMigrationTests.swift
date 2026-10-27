import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextImportCards
import CmuxNextImportSuggestions
import CmuxNextOnboarding
import Foundation
import Testing

/// The one-time classic migration at launch, end to end: the real daemon, the
/// app's restore, and classic's session file `session-groups.json` (two
/// windows, groups, a colored and a pinned workspace, a Cloud VM workspace;
/// see ``ClassicMigrationPlannerTests``). Each test is one person's upgrade
/// path from classic: first launch, relaunch, downgrade and upgrade again, a
/// run cut off midway, then Import Workspaces from Classic cmux. A later
/// launch is the launch's own run again (`migrateClassic(.automatic)`) on the
/// same daemon tree, which is what a relaunch restores.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClassicMigrationTests {
    private static let fixture = ClassicMigrationPlannerTests.fixture

    /// What the tree holds after a run.
    private struct Tree {
        /// Workspace names (Home and the launch's New Tab page left out).
        var names: [String] = []
        /// Group name by workspace name.
        var groups: [String: String] = [:]
        var colors: [String: String] = [:]
        var pinned: Set<String> = []
        /// Group names with whether each is collapsed.
        var groupNames: [String: Bool] = [:]
        /// Workspace names per window that holds any of them.
        var windows: [[String]] = []
        var notice: String?
    }

    /// A Mac that ran classic: its session file, a daemon state folder and
    /// the migration's folder, all under one scratch folder.
    private final class Mac {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-migrate-\(UUID().uuidString.prefix(8))")
        var session: URL { root.appendingPathComponent("session-com.cmuxterm.app.json") }
        var migration: URL { root.appendingPathComponent("migration") }
        var ledger: URL { migration.appendingPathComponent("ledger.json") }

        init(edit: (inout [String: Any]) -> Void = { _ in }) throws {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("proj/api/logs"), withIntermediateDirectories: true)
            for folder in ["web", "db"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("proj/\(folder)"), withIntermediateDirectories: true)
            }
            try write(edit)
        }

        /// Classic saves its session (again): `edit` changes the fixture first.
        func write(_ edit: (inout [String: Any]) -> Void) throws {
            let text = try String(contentsOf: ClassicMigrationTests.fixture, encoding: .utf8)
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "/Users/cmux/p4rt-classic/proj", with: root.appendingPathComponent("proj").path)
                .replacingOccurrences(of: "/Users/cmux", with: root.path)
            var json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            edit(&json)
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: session, options: .atomic)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// The first app launch on `mac`: restore and the launch's migration, then `after`.
    private func launch(_ mac: Mac, state: String = "state", confirm: Bool = true,
                        after: @MainActor (AppServices) async throws -> Void = { _ in }) async throws -> Tree {
        let binary = try #require(SameTreeDaemonBinary.url)
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-migrate-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: mac.root.appendingPathComponent(state)),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.onboarding.classicSessions = ClassicSessionImporter(fileURL: mac.session)
        services.onboarding.classicMigrationDirectory = mac.migration
        services.onboarding.classicMigrationAtLaunch = true
        services.onboarding.classicRunning = { false }
        services.onboarding.classicMigrationConfirmation = { _ in confirm }
        services.onboarding.classicChatPlan = { _, _ in nil }
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        defer {
            services.daemon.shutdownConnection()
            for controller in services.windows.controllers { controller.window?.close() }
        }
        let result: Result<Tree, any Error>
        do {
            try await Self.awaitMigration(services)
            try await after(services)
            result = .success(Self.read(services))
        } catch { result = .failure(error) }
        if let connection = services.daemon.connection {
            services.daemon.shutdownConnection()
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
        return try result.get()
    }

    /// Waits for restore and the migration run it starts.
    private static func awaitMigration(_ services: AppServices) async throws {
        let deadline = ContinuousClock.now + .seconds(90)
        while services.onboarding.classicMigrationRun == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let run = try #require(services.onboarding.classicMigrationRun, "launch started no classic migration")
        // A run that failed (a damaged file) is the test's to judge.
        _ = await run.result
    }

    /// A later launch's run, on the same tree.
    @discardableResult
    private static func relaunch(_ services: AppServices) async throws -> ClassicMigrationOutcome {
        try await AppOnboardingServices(owner: services.onboarding).migrateClassic(.automatic) { _ in true }
    }

    private static func read(_ services: AppServices) -> Tree {
        let store = services.daemon.store
        var tree = Tree(notice: services.onboarding.classicImportNotice)
        let groups = Dictionary(store.personal.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        tree.groupNames = Dictionary(store.personal.groups.map { ($0.name, $0.collapsed) }, uniquingKeysWith: { first, _ in first })
        let mine = store.workspaces.filter { $0.kind != "home" && !$0.screens.flatMap(\.panes).isEmpty }
        for workspace in mine {
            tree.names.append(workspace.name)
            // Personal group membership lives in the home session's personal state.
            let personal = store.registryID.flatMap { session in
                workspace.key.flatMap { store.personal.workspace(session: session, key: $0.rawValue) }
            }
            if let group = (personal?.group ?? workspace.group).flatMap({ groups[$0] }) { tree.groups[workspace.name] = group.name }
            if let color = workspace.color { tree.colors[workspace.name] = color }
            if workspace.pinned { tree.pinned.insert(workspace.name) }
        }
        let byID = Dictionary(mine.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        tree.windows = services.windows.registry.value.windows.map { $0.workspaceIDs.compactMap { byID[$0] } }.filter { !$0.isEmpty }
        return tree
    }

    private static let classicNames = ["split api", "pinned one", "second window"]

    @Test func launchMigrationRestoresNothingWhenThePreviewIsCancelled() async throws {
        let mac = try Mac()
        let tree = try await launch(mac, confirm: false)
        #expect(tree.names.allSatisfy { !Self.classicNames.contains($0) }, "\(tree.names)")
        #expect(!FileManager.default.fileExists(atPath: mac.ledger.path))
        #expect(!FileManager.default.fileExists(atPath: mac.migration.appendingPathComponent("backups").path))
    }

    /// First launch after the upgrade: every classic window comes back with its
    /// workspaces, groups, colors and pin; the Cloud VM workspace and the
    /// repeated one do not; the launch's empty New Tab page gives way.
    @Test func theFirstLaunchBringsWindowsGroupsColorsAndPins() async throws {
        let mac = try Mac()
        let before = try Data(contentsOf: mac.session)
        let tree = try await launch(mac)
        for name in Self.classicNames { #expect(tree.names.contains(name), "\(tree.names)") }
        #expect(!tree.names.contains("vm box") && !tree.names.contains("duplicate of split"), "\(tree.names)")
        #expect(tree.groups["split api"] == "Backend" && tree.groups["pinned one"] == "Backend", "\(tree.groups)")
        #expect(tree.groupNames["Backend"] == true && tree.groupNames["Saved"] != nil, "\(tree.groupNames)")
        #expect(tree.colors["split api"]?.uppercased().hasPrefix("#FF6B6B") == true, "\(tree.colors)")
        #expect(tree.pinned.contains("pinned one"), "\(tree.pinned)")
        #expect(tree.windows.contains { $0.contains("second window") && !$0.contains("split api") }, "\(tree.windows)")
        #expect(tree.notice?.contains("Cloud VM") == true, "\(tree.notice ?? "no toast")")
        // The classic session file is never written; a copy is kept in the migration's folder.
        #expect(try Data(contentsOf: mac.session) == before)
        #expect(FileManager.default.fileExists(atPath: mac.migration.appendingPathComponent("backups").path))
    }

    /// Relaunching makes nothing again, and Import Workspaces from Classic
    /// cmux says every workspace is already here instead of duplicating them.
    @Test func aRelaunchAndTheActionMakeNoDuplicates() async throws {
        let mac = try Mac()
        var first: [String] = []
        let tree = try await launch(mac) { services in
            first = Self.read(services).names
            let again = try await Self.relaunch(services)
            #expect(again.decision == .skip(.unchanged) && again.opened.isEmpty, "\(again)")
            var ran = false
            let work = services.registry.capturingWork { ran = services.registry.perform("workspace.importClassic") }
            #expect(ran)
            for task in work { #expect(await task.value == nil) }
        }
        // Classic's workspaces, each once (the launch's empty New Tab page may close meanwhile).
        let classic = { (names: [String]) in names.filter(Self.classicNames.contains).sorted() }
        #expect(classic(tree.names) == classic(first) && classic(first) == Self.classicNames.sorted(), "\(first) then \(tree.names)")
        // The Cloud VM workspace still stays in classic, and the toast still says so.
        #expect(tree.notice?.hasPrefix(ClassicImportStrings.allHere) == true, "\(tree.notice ?? "no toast")")
    }

    /// What the cmux Classic card's runs reported.
    @MainActor private final class CardRuns {
        var progress: [Double] = []
        var opened: [Int?] = []
        var statuses: [String?] = []
    }

    /// The cmux Classic card in Settings › Import runs the action's own import as a tracked job:
    /// progress that moves with each classic workspace, then "Imported N sessions". Run again,
    /// the migration ledger opens nothing twice and the card says "Imported 0 sessions".
    @Test func theClassicCardImportsAsAJobAndASecondRunOpensNothing() async throws {
        let mac = try Mac()
        let runs = CardRuns()
        let tree = try await launch(mac, confirm: false) { services in
            services.onboarding.classicMigrationConfirmation = { _ in true }
            let defaults = try #require(UserDefaults(suiteName: "cn-migrate-cards-\(UUID().uuidString)"))
            let center = ImportSuggestionsCenter(defaults: defaults, ledgerURL: mac.root.appendingPathComponent("import-jobs.json"))
            center.scanThisMac = { _ in [ImportFinding(id: "cmux.classic", kind: .cmuxClassic, name: "cmux Classic", count: 3)] }
            var host = OnboardingHandlers.importCardsHost(services)
            let shared = host.importClassic
            host.importClassic = { report in
                let opened = try await shared { fraction in
                    runs.progress.append(fraction)
                    report(fraction)
                }
                runs.opened.append(opened)
                return opened
            }
            center.host = host
            await withCheckedContinuation { done in center.scan { done.resume() } }
            for _ in 0..<2 {
                try center.perform("cmux.classic", .start)
                await center.settled("cmux.classic")
                runs.statuses.append(center.list().cards.first { $0.id == "cmux.classic" }?.status)
            }
        }
        let first = try #require(runs.opened.first ?? nil)
        #expect(first >= 3 && runs.opened.count == 2 && runs.opened.last == 0, "\(runs.opened)")
        #expect(runs.statuses == ["Imported \(first) sessions", "Imported 0 sessions"], "\(runs.statuses)")
        // Progress moved up as each workspace was handled, to the whole run.
        #expect(runs.progress.count >= first && runs.progress == runs.progress.sorted() && runs.progress.last == 1, "\(runs.progress)")
        let classic = tree.names.filter(Self.classicNames.contains).sorted()
        #expect(classic == Self.classicNames.sorted(), "\(tree.names)")
    }

    /// Downgrade to classic, which makes a workspace in the Backend group and
    /// renames one that already came over, then upgrade again: only the new
    /// workspace comes over, into the same group; the rename is not merged.
    @Test func aReUpgradeMergesOnlyWhatClassicMadeMeanwhile() async throws {
        let mac = try Mac()
        let tree = try await launch(mac) { services in
            try mac.write { root in
                root["createdAt"] = 1_891_728_605.0
                var windows = root["windows"] as? [[String: Any]] ?? []
                var manager = windows[0]["tabManager"] as? [String: Any] ?? [:]
                var workspaces = manager["workspaces"] as? [[String: Any]] ?? []
                var added = workspaces[0]
                added["stableId"] = "AAAAAAAA-0000-4000-8000-000000000099"
                added["customTitle"] = "made while downgraded"
                added["customTitleSource"] = "user"
                added["groupId"] = ClassicMigrationPlannerTests.backend
                workspaces[1]["customTitle"] = "renamed in classic"
                workspaces.append(added)
                manager["workspaces"] = workspaces
                windows[0]["tabManager"] = manager
                root["windows"] = windows
            }
            let merge = try await Self.relaunch(services)
            #expect(merge.decision == .merge && merge.opened.count == 1, "\(merge)")
            // The new workspace's group lands with the daemon's next events, after the run returns.
            let deadline = ContinuousClock.now + .seconds(5)
            while Self.read(services).groups["made while downgraded"] == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        #expect(tree.names.filter { $0 == "made while downgraded" }.count == 1, "\(tree.names)")
        #expect(tree.names.filter { $0 == "split api" }.count == 1 && !tree.names.contains("renamed in classic"), "\(tree.names)")
        #expect(tree.groups["made while downgraded"] == "Backend", "\(tree.groups)")
        #expect(tree.groups.values.filter { $0 == "Backend" }.count == 3, "\(tree.groups)")
    }

    /// The app quit while "pinned one" was half made: the next launch closes
    /// the half-made workspace and makes it once.
    @Test func aRunCutOffMidwayResumesWithoutDuplicates() async throws {
        let mac = try Mac()
        let key = ClassicMigrationPlannerTests.pinned
        let tree = try await launch(mac) { services in
            var ledger = try JSONDecoder().decode(ClassicMigrationLedger.self, from: Data(contentsOf: mac.ledger))
            ledger.state = .inProgress
            ledger.workspaces[key]?.stage = .created
            try JSONEncoder().encode(ledger).write(to: mac.ledger, options: .atomic)
            let resume = try await Self.relaunch(services)
            #expect(resume.decision == .resume && resume.opened.count == 1, "\(resume)")
        }
        #expect(tree.names.filter { $0 == "pinned one" }.count == 1, "\(tree.names)")
        let resumed = try JSONDecoder().decode(ClassicMigrationLedger.self, from: Data(contentsOf: mac.ledger))
        #expect(resumed.state == .completed && resumed.workspaces[key]?.stage == .done && resumed.runs == 2)
    }

    /// A damaged session file migrates nothing and breaks no launch; once
    /// classic saves a good one, the next launch migrates it.
    @Test func aDamagedSessionFileIsLeftAndRetriedOnceClassicSavesAgain() async throws {
        let mac = try Mac()
        try Data("{\"windows\": [".utf8).write(to: mac.session)
        let tree = try await launch(mac) { services in
            let broken = Self.read(services).names
            #expect(broken.allSatisfy { !Self.classicNames.contains($0) }, "\(broken)")
            try mac.write { _ in }
            let merge = try await Self.relaunch(services)
            #expect(merge.decision == .merge, "\(merge)")
        }
        for name in Self.classicNames { #expect(tree.names.contains(name), "\(tree.names)") }
    }
}

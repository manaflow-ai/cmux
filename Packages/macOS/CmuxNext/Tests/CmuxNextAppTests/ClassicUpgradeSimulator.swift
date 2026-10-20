import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextOnboarding
import CryptoKit
import Foundation
import Testing

/// Runs one simulated classic user's upgrade on the real daemon and checks the
/// upgrade promise: nothing lost, nothing made twice, windows, order, groups,
/// pins, colors and split layouts as in classic, no prompt, the first window
/// before the migration's work, and classic's files byte for byte unchanged.
@MainActor
final class ClassicUpgradeSimulator {
    /// The scratch Mac: Application Support with classic's `cmux` folder, the
    /// daemon's state and cmux-next's migration folder.
    final class Mac {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-upgrade-\(UUID().uuidString.prefix(8))")
        var support: URL { root.appendingPathComponent("Application Support", isDirectory: true) }
        var classic: URL { support.appendingPathComponent("cmux", isDirectory: true) }
        var migration: URL { root.appendingPathComponent("migration", isDirectory: true) }
        var ledger: URL { migration.appendingPathComponent("ledger.json") }
        var home: String { root.appendingPathComponent("home").path }
        /// Classic's state folder (`~/.local/state/cmux`), holding its launch sentinel.
        var state: URL { root.appendingPathComponent("classic-state", isDirectory: true) }

        /// Classic launches (writes its sentinel) or quits cleanly (removes it).
        func classicRunning(_ running: Bool, bundle: String = "com.cmuxterm.app") throws {
            let sentinel = ClassicRunningProbe(stateRoot: state).sentinel(channel: bundle)
            if running {
                try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("pid=4242\n".utf8).write(to: sentinel)
            } else {
                try? FileManager.default.removeItem(at: sentinel)
            }
        }

        init() throws {
            try FileManager.default.createDirectory(at: classic, withIntermediateDirectories: true)
            for folder in ["proj/api", "proj/web", "proj/db"] {
                try FileManager.default.createDirectory(atPath: home + "/" + folder, withIntermediateDirectories: true)
            }
        }

        func session(_ bundle: String = "com.cmuxterm.app", suffix: String = "") -> URL {
            classic.appendingPathComponent("session-\(bundle)\(suffix).json")
        }

        /// Classic saves `profile` as its session (the way it does: atomically).
        func save(_ profile: ClassicUpgradeProfile, bundle: String = "com.cmuxterm.app", suffix: String = "") throws {
            try profile.sessionData(home: home).write(to: session(bundle, suffix: suffix), options: .atomic)
        }

        /// Every file under classic's folder with its SHA-256.
        func classicDigest() throws -> [String: String] {
            var digest: [String: String] = [:]
            let enumerator = FileManager.default.enumerator(at: classic, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = enumerator?.nextObject() as? URL {
                guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
                let data = try Data(contentsOf: url)
                digest[String(url.path.dropFirst(classic.path.count))] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            return digest
        }

        func readLedger() throws -> ClassicMigrationLedger {
            try JSONDecoder().decode(ClassicMigrationLedger.self, from: Data(contentsOf: ledger))
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// What the launch did and how long it took.
    struct Launch {
        var outcome: ClassicMigrationOutcome?
        var failure: (any Error)?
        /// Daemon start to restore done (the first window shows the tree).
        var firstWindow: Duration = .zero
        /// The migration run itself, after restore.
        var migration: Duration = .zero
    }

    /// One workspace as cmux-next has it.
    struct Made: Equatable {
        var name: String
        var group: String?
        var pinned: Bool
        var color: String?
        /// Tabs per pane, sorted.
        var panes: [Int]
    }

    let mac: Mac
    let services: AppServices
    private let launcher: DaemonLauncher
    /// Seconds since the migration started at which each workspace name first showed (``watch()``).
    private(set) var appeared: [String: Double] = [:]
    private var watcher: Task<Void, Never>?

    /// - Parameter ssh: the daemon for an SSH destination (default: none connects).
    init(mac: Mac, ssh: (@MainActor (String) throws -> DaemonService)? = nil) throws {
        self.mac = mac
        let binary = try #require(SameTreeDaemonBinary.url)
        launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-upgrade-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: mac.root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.onboarding.classicMigrationSupport = mac.support
        services.onboarding.classicMigrationDirectory = mac.migration
        services.onboarding.classicMigrationAtLaunch = true
        services.onboarding.classicStateRoot = mac.state
        if let ssh { services.onboarding.classicSSH = ssh }
        else { services.onboarding.classicSSH = { destination in DaemonService(machineID: "ssh:\(destination)") } }
        services.onboarding.classicChatPlan = { _, _ in nil }
    }

    /// The first launch after the update: restore, then the launch's own migration run.
    func launch() async -> Launch {
        let clock = ContinuousClock()
        let start = clock.now
        let launcher = self.launcher
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        var result = Launch()
        let deadline = clock.now + .seconds(90)
        // The run is set by restore's last step; the test can only look for it.
        while services.onboarding.classicMigrationRun == nil, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        result.firstWindow = clock.now - start
        guard let run = services.onboarding.classicMigrationRun else {
            result.failure = SimulationFailure.noRun
            return result
        }
        let migrating = clock.now
        watch(from: migrating)
        switch await run.result {
        case .success(let outcome): result.outcome = outcome
        case .failure(let error): result.failure = error
        }
        result.migration = clock.now - migrating
        watcher?.cancel()
        return result
    }

    /// A later launch's run on the same tree (what a relaunch restores).
    func relaunch() async throws -> ClassicMigrationOutcome {
        try await AppOnboardingServices(owner: services.onboarding).migrateClassic(.automatic)
    }

    /// Import Workspaces from Classic cmux.
    func manualImport() async throws -> ClassicMigrationOutcome {
        try await AppOnboardingServices(owner: services.onboarding).migrateClassic(.manual)
    }

    func shutdown() async {
        watcher?.cancel()
        let connection = services.daemon.connection
        services.daemon.shutdownConnection()
        for controller in services.windows.controllers { controller.window?.close() }
        if let connection {
            await connection.close()
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
    }

    /// Records when each workspace first shows, every 50 ms (test-side sampling of the store).
    private func watch(from start: ContinuousClock.Instant) {
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                let seconds = (ContinuousClock.now - start).simSeconds
                for workspace in self.services.daemon.store.workspaces where self.appeared[workspace.name] == nil {
                    self.appeared[workspace.name] = seconds
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Workspaces made from classic (Home and the launch's empty New Tab page left out), by id.
    func made() -> [String: Made] {
        let store = services.daemon.store
        let groups = Dictionary(store.personal.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var made: [String: Made] = [:]
        for workspace in store.workspaces where workspace.kind != "home" && !workspace.screens.flatMap(\.panes).isEmpty {
            let personal = store.registryID.flatMap { session in
                workspace.key.flatMap { store.personal.workspace(session: session, key: $0.rawValue) }
            }
            let group = (personal?.group ?? workspace.group).flatMap { groups[$0] }?.name
            made[workspace.id] = Made(name: workspace.name, group: group, pinned: workspace.pinned, color: workspace.color,
                                      panes: workspace.screens.flatMap(\.panes).map(\.tabs.count).sorted())
        }
        return made
    }

    /// Group name to collapsed, for every personal group.
    func groups() -> [String: Bool] {
        Dictionary(services.daemon.store.personal.groups.map { ($0.name, $0.collapsed) }, uniquingKeysWith: { first, _ in first })
    }

    /// Workspace ids per window, in sidebar order.
    func windows() -> [[String]] {
        services.windows.registry.value.windows.map(\.workspaceIDs)
    }

    /// Whether anything asked the person something (a modal or a sheet).
    func prompted() -> Bool {
        NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
    }

    /// Checks `profile`'s promise against the tree after the run(s).
    /// - Parameter source: the classic file the run read (default: the session file).
    func verify(_ profile: ClassicUpgradeProfile, classicBefore: [String: String], source: URL? = nil,
                sourceLocation: SourceLocation = #_sourceLocation) throws {
        let label = profile.name
        // The file on disk: panel ids (and so older snapshots' keys) are made when it is written.
        let file = source ?? mac.session()
        let decoded = try ClassicSessionImporter(fileURL: file).decodeSnapshot(Data(contentsOf: file))
        let ledger = try mac.readLedger()
        let made = made()
        let windows = windows()
        // The decoder keeps classic's order and count, so it lines up with the profile.
        var expectedIDs: [[String]] = []
        var seen = Set<String>()
        for (window, saved) in zip(profile.windows, decoded.windows) {
            var ids: [String] = []
            for (workspace, read) in zip(window.workspaces, saved.workspaces) {
                guard workspace.comesOver, seen.insert(read.key).inserted else { continue }
                let entry = ledger.workspaces[read.key]
                guard entry?.stage == .done, let id = entry?.nextWorkspace, let here = made[id] else {
                    Issue.record("\(label): \(read.name) was lost (ledger \(String(describing: entry)))", sourceLocation: sourceLocation)
                    continue
                }
                ids.append(id)
                if let title = workspace.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
                    #expect(here.name.trimmingCharacters(in: .whitespaces) == title,
                            "\(label): name \(here.name) for \(title)", sourceLocation: sourceLocation)
                }
                #expect(here.panes == workspace.layout.expectedPanes.sorted(),
                        "\(label): \(here.name) panes \(here.panes), classic \(workspace.layout.expectedPanes)", sourceLocation: sourceLocation)
                let group = workspace.group.flatMap { profile.groupNames[$0] }
                #expect(here.group == (profile.legacyKeys ? nil : group), "\(label): \(here.name) group \(String(describing: here.group))",
                        sourceLocation: sourceLocation)
                if !profile.legacyKeys {
                    #expect(here.pinned == workspace.pinned, "\(label): \(here.name) pin", sourceLocation: sourceLocation)
                    if let color = workspace.color {
                        #expect(here.color?.uppercased().hasPrefix(color.uppercased()) == true,
                                "\(label): \(here.name) color \(String(describing: here.color))", sourceLocation: sourceLocation)
                    }
                }
            }
            if !ids.isEmpty { expectedIDs.append(ids) }
        }
        // Nothing twice, nothing extra.
        let all = expectedIDs.flatMap { $0 }
        #expect(Set(all).count == all.count, "\(label): one workspace recorded twice", sourceLocation: sourceLocation)
        #expect(made.count == profile.expectedCount,
                "\(label): \(made.count) workspaces, classic had \(profile.expectedCount): \(made.values.map(\.name).sorted())",
                sourceLocation: sourceLocation)
        // Each classic window is one cmux-next window, in classic's order.
        for ids in expectedIDs {
            let window = windows.first { $0.contains(ids[0]) } ?? []
            #expect(window.filter(Set(ids).contains) == ids, "\(label): order in window differs", sourceLocation: sourceLocation)
        }
        let distinct = Set(expectedIDs.map { ids in windows.firstIndex { $0.contains(ids[0]) } ?? -1 })
        #expect(distinct.count == expectedIDs.count, "\(label): classic windows merged", sourceLocation: sourceLocation)
        // Groups with their collapsed state (members or pinned).
        if !profile.legacyKeys {
            let here = groups()
            for group in profile.windows.flatMap(\.groups) where !group.id.isEmpty {
                let used = profile.expectedWindows.flatMap { $0 }.contains { $0.group == group.id }
                guard used || group.pinned else { continue }
                #expect(here[group.name] == group.collapsed, "\(label): group \(group.name) \(String(describing: here[group.name]))",
                        sourceLocation: sourceLocation)
            }
        }
        #expect(!prompted(), "\(label): a prompt showed", sourceLocation: sourceLocation)
        #expect(try mac.classicDigest() == classicBefore, "\(label): classic's files changed", sourceLocation: sourceLocation)
    }

    enum SimulationFailure: Error { case noRun }
}

extension Duration {
    /// The duration in seconds, for budgets and reports.
    var simSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextOnboarding
import CmuxNextSidebar
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
    /// Seconds since the migration started at which each classic key first showed in the ledger
    /// (the run's turn for that workspace began), sampled with ``appeared``.
    private(set) var ledgered: [String: Double] = [:]
    /// The last run's outcome (launch, relaunch, import), for its failures.
    private(set) var lastOutcome: ClassicMigrationOutcome?
    /// Workspaces the launch made before the migration (its empty New Tab page).
    private(set) var launchMade: Set<String> = []
    private var watcher: Task<Void, Never>?
    /// When the launch's migration run started (``launch(deadline:)``); ``wait(for:upTo:)`` samples from it too.
    private var migrationStart: ContinuousClock.Instant?

    /// - Parameters:
    ///   - ssh: the daemon for an SSH destination (default: none connects).
    ///   - documentRemote: wraps the home daemon's sidebar document remote (a test holds its replies).
    init(mac: Mac, ssh: (@MainActor (String) throws -> DaemonService)? = nil,
         documentRemote: (@MainActor (any SidebarDocRemote) -> any SidebarDocRemote)? = nil) throws {
        self.mac = mac
        let binary = try #require(SameTreeDaemonBinary.url)
        launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-upgrade-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: mac.root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        services = AppServices(environment: AppEnvironment.current([:]))
        if let documentRemote {
            // `AppServices.sidebarLayout`'s own start, with the document's remote wrapped.
            let services = services
            let layout = SidebarLayoutService(remote: DaemonSidebarLayoutRemote(services: services),
                                              onRefused: { [weak services] message in services?.registry.refuse(message) })
            layout.start()
            services.sidebarDoc.start(services, layout: layout, wrapping: documentRemote)
            services.sidebarLayout = layout
        }
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.onboarding.classicMigrationSupport = mac.support
        services.onboarding.classicMigrationDirectory = mac.migration
        services.onboarding.classicMigrationAtLaunch = true
        services.onboarding.classicStateRoot = mac.state
        services.onboarding.classicMigrationConfirmation = { _ in true }
        if let ssh { services.onboarding.classicSSH = ssh }
        else { services.onboarding.classicSSH = { destination in DaemonService(machineID: "ssh:\(destination)") } }
        services.onboarding.classicChatPlan = { _, _ in nil }
    }

    /// The first launch after the update: restore, then the launch's own migration run.
    ///
    /// - Parameter deadline: how long the migration may run before the
    ///   simulation stops waiting and reports where it got to (it prints
    ///   `CLASSIC-SIM progress` every 10 s meanwhile).
    func launch(deadline budget: Duration = .seconds(150)) async -> Launch {
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
        launchMade = Set(made().keys)
        migrationStart = migrating
        watch(from: migrating)
        final class Box { var result: Result<ClassicMigrationOutcome, any Error>? }
        let box = Box()
        let waiter = Task { @MainActor in box.result = await run.result }
        var lastReport = clock.now
        while box.result == nil, clock.now - migrating < budget {
            try? await Task.sleep(for: .milliseconds(100))
            if clock.now - lastReport >= .seconds(10) {
                lastReport = clock.now
                let ledger = try? mac.readLedger()
                let stages = Dictionary(grouping: ledger?.workspaces.values.map(\.stage.rawValue) ?? [], by: { $0 }).mapValues(\.count)
                print("CLASSIC-SIM progress t=\(Int((clock.now - migrating).simSeconds))s made=\(made().count) ledger=\(stages)")
            }
        }
        switch box.result {
        case .success(let outcome)?:
            result.outcome = outcome
            lastOutcome = outcome
        case .failure(let error)?: result.failure = error
        case nil:
            waiter.cancel()
            result.failure = SimulationFailure.overBudget(made: made().count)
        }
        result.migration = clock.now - migrating
        watcher?.cancel()
        // The run's last turns (the SSH workspaces, after their connect limit) can end it within one sampling tick.
        sample(from: migrating)
        // The launch's empty New Tab page closes at the run's end; its close reaches the store a moment later
        // (a ceiling, not a budget: a loaded Mac takes longer).
        if result.outcome?.opened.isEmpty == false {
            let settle = clock.now + .seconds(60)
            while clock.now < settle, !launchMade.isDisjoint(with: made().keys) { try? await Task.sleep(for: .milliseconds(50)) }
        }
        return result
    }

    /// `run`'s outcome once it finishes within `budget`, printing progress
    /// every 10 s; nil when it is still running (it keeps running).
    func wait(for run: Task<ClassicMigrationOutcome, any Error>, upTo budget: Duration) async -> ClassicMigrationOutcome? {
        final class Box { var result: Result<ClassicMigrationOutcome, any Error>? }
        let box = Box()
        let waiter = Task { @MainActor in box.result = await run.result }
        let clock = ContinuousClock()
        let start = clock.now
        // The run's turns keep being sampled past the launch's deadline (``perWorkspaceReport()``).
        if let migrationStart { watch(from: migrationStart) }
        defer {
            watcher?.cancel()
            if let migrationStart { sample(from: migrationStart) }
        }
        var lastReport = clock.now
        while box.result == nil, clock.now - start < budget {
            try? await Task.sleep(for: .milliseconds(100))
            if clock.now - lastReport >= .seconds(10) {
                lastReport = clock.now
                print("CLASSIC-SIM progress made=\(made().count)")
            }
        }
        waiter.cancel()
        guard case .success(let outcome)? = box.result else { return nil }
        lastOutcome = outcome
        return outcome
    }

    /// A later launch's run on the same tree (what a relaunch restores).
    func relaunch() async throws -> ClassicMigrationOutcome {
        let outcome = try await AppOnboardingServices(owner: services.onboarding)
            .migrateClassic(.automatic) { _ in true }
        lastOutcome = outcome
        return outcome
    }

    /// Import Workspaces from Classic cmux.
    func manualImport() async throws -> ClassicMigrationOutcome {
        let outcome = try await AppOnboardingServices(owner: services.onboarding)
            .migrateClassic(.manual) { _ in true }
        lastOutcome = outcome
        return outcome
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

    /// Each classic workspace's turn: the time from its key's first entry in the ledger to the
    /// next one's, sampled every 50 ms (``watch(from:)``). p50, p95, the mean of the first and
    /// last 64 turns, and first entry to last.
    func perWorkspaceReport() -> String {
        let starts = ledgered.values.sorted()
        let turns = zip(starts, starts.dropFirst()).map { ($1 - $0) * 1000 }
        guard !turns.isEmpty else { return "per_workspace n=0" }
        let sorted = turns.sorted()
        let at = { (share: Double) in sorted[min(sorted.count - 1, Int((share * Double(sorted.count)).rounded(.up)) - 1)] }
        let mean = { (slice: ArraySlice<Double>) in slice.reduce(0, +) / Double(max(slice.count, 1)) }
        return String(format: "per_workspace n=%d p50=%.0fms p95=%.0fms first64=%.0fms last64=%.0fms span=%.1fs",
                      turns.count, at(0.5), at(0.95), mean(turns.prefix(64)), mean(turns.suffix(64)), (starts.last ?? 0) - (starts.first ?? 0))
    }

    /// Records when each workspace first shows, and when each classic key first shows in the
    /// ledger, every 50 ms (test-side sampling of the store and the ledger file).
    private func watch(from start: ContinuousClock.Instant) {
        watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                self.sample(from: start)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// One sample for ``watch(from:)``: the workspaces in the store and the keys in the ledger not seen before.
    private func sample(from start: ContinuousClock.Instant) {
        let seconds = (ContinuousClock.now - start).simSeconds
        for workspace in services.daemon.store.workspaces where appeared[workspace.name] == nil {
            appeared[workspace.name] = seconds
        }
        if let ledger = try? mac.readLedger() {
            for key in ledger.workspaces.keys where ledgered[key] == nil { ledgered[key] = seconds }
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

    /// Each window's sidebar containers (loose rows, then each group), workspace ids in the order shown.
    func windows() -> [[[String]]] {
        services.windows.registry.value.windows.map { window in
            SidebarBridge.sections(services.machines, doc: services.sidebarDoc, members: window.workspaceIDs, profile: .defaultProfile).flatMap { section in
                var loose: [String] = []
                var groups: [[String]] = []
                for node in section.nodes {
                    switch node {
                    case .workspace(let workspace): loose.append(workspace.id.rawValue)
                    case .group(let group): groups.append(group.workspaces.map(\.id.rawValue))
                    case .item: break
                    }
                }
                return [loose] + groups
            }
        }
    }

    /// Whether anything asked the person something (a modal or a sheet).
    func prompted() -> Bool {
        NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil }
    }

    /// Waits until every placement the run asked for has landed (the daemon's
    /// last events of a run land after the run returns): the personal queue
    /// through, the sidebar document's moves and adopts answered, the store
    /// caught up with the daemon after them, no new-workspace placement left and
    /// the sidebar's projection current (``AppServices/placementsSettled(timeout:sourceLocation:)``).
    /// No quiet window: an idle Mac gets there at once, a loaded one later, and a
    /// hang past 60 s is recorded as an issue naming what is still in flight.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        await services.placementsSettled(sourceLocation: sourceLocation)
    }

    /// Checks `profile`'s promise against the tree after the run(s).
    /// - Parameter source: the classic file the run read (default: the session file).
    ///   - ignoring: cmux-next workspaces that are not classic's (one the person made before).
    ///   - excusing: classic keys whose workspace is allowed not to have opened (a declared known limit).
    ///   - orderIsKnownIssue: classic's order is a declared known issue (a resumed run makes its workspaces last).
    func verify(_ profile: ClassicUpgradeProfile, classicBefore: [String: String], source: URL? = nil, ignoring: Set<String> = [],
                excusing: Set<String> = [], orderIsKnownIssue: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let label = profile.name
        // The file on disk: panel ids (and so older snapshots' keys) are made when it is written.
        let file = source ?? mac.session()
        let decoded = try ClassicSessionImporter(fileURL: file).decodeSnapshot(Data(contentsOf: file))
        let ledger = try mac.readLedger()
        let made = made().filter { !ignoring.contains($0.key) }
        if let outcome = lastOutcome, let failure = outcome.failures.first(where: { !excusing.contains($0.key) }) {
            Issue.record("\(label): \(outcome.failures.count) workspaces failed, first: \(failure.value)", sourceLocation: sourceLocation)
        }
        let windows = windows()
        // The decoder keeps classic's order and count, so it lines up with the profile.
        var expectedIDs: [[String]] = []
        var seen = Set<String>()
        for (window, saved) in zip(profile.windows, decoded.windows) {
            var ids: [String] = []
            for (workspace, read) in zip(window.workspaces, saved.workspaces) {
                guard workspace.comesOver, seen.insert(read.key).inserted, !excusing.contains(read.key) else { continue }
                let entry = ledger.workspaces[read.key]
                guard entry?.stage == .done, let id = entry?.nextWorkspace, let here = made[id] else {
                    Issue.record("\(label): \(read.name) was lost (ledger \(String(describing: entry)))", sourceLocation: sourceLocation)
                    continue
                }
                ids.append(id)
                if let title = workspace.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
                    let name = here.name.trimmingCharacters(in: .whitespaces)
                    // A title past the daemon's limit comes over cut.
                    let fits = title.utf8.count <= ClassicSessionImporter.maximumNameBytes ? name == title : title.hasPrefix(name) && !name.isEmpty
                    #expect(fits, "\(label): name \(here.name.prefix(80)) for \(title.prefix(80))", sourceLocation: sourceLocation)
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
        #expect(made.count == profile.expectedCount - excusing.count,
                "\(label): \(made.count) workspaces, classic had \(profile.expectedCount): \(made.values.map(\.name).sorted())",
                sourceLocation: sourceLocation)
        // Each classic window is one cmux-next window; in each of its sidebar
        // containers (loose rows, a group) classic's workspaces show in classic's order.
        for ids in expectedIDs {
            let window = windows.first { $0.joined().contains(ids[0]) } ?? []
            for container in window {
                let shown = container.filter(Set(ids).contains)
                let classic = ids.filter(Set(shown).contains)
                let check = {
                    #expect(shown == classic, "\(label): order differs: \(shown.compactMap { made[$0]?.name.prefix(20) }) for \(classic.compactMap { made[$0]?.name.prefix(20) })",
                            sourceLocation: sourceLocation)
                }
                if orderIsKnownIssue {
                    withKnownIssue("a resumed run makes its workspaces last in the sidebar", isIntermittent: true, sourceLocation: sourceLocation, check)
                } else {
                    check()
                }
            }
            let listed = Set(window.joined())
            #expect(ids.allSatisfy(listed.contains), "\(label): a workspace is missing from its window's sidebar", sourceLocation: sourceLocation)
        }
        let distinct = Set(expectedIDs.map { ids in windows.firstIndex { $0.joined().contains(ids[0]) } ?? -1 })
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

    enum SimulationFailure: Error {
        case noRun
        /// The migration was still running at the deadline, with `made` workspaces made.
        case overBudget(made: Int)
    }
}

extension Duration {
    /// The duration in seconds, for budgets and reports.
    var simSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

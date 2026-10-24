import AppKit
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextOnboarding
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation

/// What one classic migration run did.
struct ClassicMigrationOutcome: Equatable {
    var decision: ClassicMigrationPlanner.Decision
    var summary = ClassicImportSummary()
    /// False when the person declined the exact plan before it wrote anything.
    var confirmed = true
    /// The cmux-next workspaces it made, in order.
    var opened: [String] = []
    /// Why classic workspaces did not open, by classic key (the next manual run tries them again).
    var failures: [String: String] = [:]
}

/// The one-time migration from classic cmux (plans/cmux-next/classic-migration-DESIGN.md).
///
/// At launch, after restore, it brings classic's last saved session over once:
/// every window, its workspaces in sidebar order with their splits and tabs,
/// their groups, colors and pins. A ledger in cmux-next's own folder records
/// each workspace before, while and after it is made, so a run cut off midway
/// resumes without duplicates and a later launch makes nothing again. After a
/// downgrade to classic and a new upgrade, only workspaces classic made in
/// between come over. Classic's files are read and backed up, never changed.
extension AppOnboardingServices {
    /// Where the ledger and backups live: `Application Support/cmux-next/<bundle id>/classic-migration`.
    var classicMigrationDirectory: URL {
        if let seam = owner.classicMigrationDirectory { return seam }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "cmux-next", directoryHint: .isDirectory)
            .appending(path: services.environment.launch.bundleID ?? "com.cmuxterm.app.next", directoryHint: .isDirectory)
            .appending(path: "classic-migration", directoryHint: .isDirectory)
    }

    /// Whether the launch runs the migration by itself: shipping builds yes;
    /// dev builds and test hosts only with `CMUX_NEXT_CLASSIC_MIGRATION=1`;
    /// `CMUX_NEXT_CLASSIC_MIGRATION=0` turns it off anywhere.
    var classicMigrationRunsAtLaunch: Bool {
        if let seam = owner.classicMigrationAtLaunch { return seam }
        switch ProcessInfo.processInfo.environment["CMUX_NEXT_CLASSIC_MIGRATION"] {
        case "0": return false
        case "1": return true
        default:
            let shipping = ClassicMigrationSourceFinder.channels + ["com.cmuxterm.app.nightly.cmux-next"]
            return services.environment.launch.bundleID.map(shipping.contains) ?? false
        }
    }

    /// The launch's run: after restore, once per classic save. Never throws;
    /// a failure is logged and the ledger keeps what came over.
    ///
    /// - Parameter firstWorkspace: the workspace launch landed on for an empty
    ///   tree: a New Tab page workspace, closed when the migration brought workspaces
    ///   into its window, or Home, which stays.
    func migrateClassicAtLaunch(firstWorkspace: String?) async {
        guard classicMigrationRunsAtLaunch else { return }
        do {
            let outcome = try await migrateClassic(.automatic, firstWorkspace: firstWorkspace,
                                                   confirmation: confirmClassicImport)
            guard !outcome.opened.isEmpty, let notice = owner.classicImportNotice else { return }
            ClassicImportStrings.toast(notice, in: services.windows.active?.window)
        } catch {
            services.daemon.logger.error("classic migration failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// One migration run. Runs never overlap: a second one waits for the first. `progress`
    /// hears the share of the plan's classic workspaces handled (opened or left), 0...1.
    func migrateClassic(_ mode: ClassicMigrationPlanner.Mode, firstWorkspace: String? = nil,
                        confirmation: @escaping @MainActor (ClassicImportPlan) async -> Bool,
                        progress: (@MainActor (Double) -> Void)? = nil) async throws -> ClassicMigrationOutcome {
        let previous = owner.classicMigrationRun
        let run = Task { @MainActor in
            _ = await previous?.result
            return try await runClassicMigration(mode, firstWorkspace: firstWorkspace, confirmation: confirmation, progress: progress)
        }
        owner.classicMigrationRun = run
        return try await run.value
    }

    /// The one confirmation path for launch and manual migration.
    func confirmClassicImport(_ plan: ClassicImportPlan) async -> Bool {
        if let confirmation = owner.classicMigrationConfirmation { return await confirmation(plan) }
        return await ClassicImportConfirmation(plan: plan, services: services).ask()
    }

    private func runClassicMigration(_ mode: ClassicMigrationPlanner.Mode, firstWorkspace: String?,
                                     confirmation: @escaping @MainActor (ClassicImportPlan) async -> Bool,
                                     progress: (@MainActor (Double) -> Void)?) async throws -> ClassicMigrationOutcome {
        let repository = ClassicMigrationRepository(directory: classicMigrationDirectory)
        let load = await repository.load()
        let planner = ClassicMigrationPlanner()
        // The first contact on this Mac is recorded whatever happens, so a later
        // launch knows the tree was fresh then (and merges) rather than in use.
        var firstContact = false
        if case .none = load, mode == .automatic { firstContact = true }
        let read: ClassicSnapshotRead?
        do {
            read = try await readClassicSnapshot()
        } catch {
            if firstContact { try? await save(ClassicMigrationLedger(state: .completed), to: repository) }
            throw error
        }
        let decision: ClassicMigrationPlanner.Decision
        switch mode {
        case .automatic:
            // cmux-next was in use before this build (the tree had workspaces of the
            // person's own): it may already hold classic's work, moved by hand or by
            // the import action. The first run only records classic's workspaces as
            // seen; later classic saves still merge, and the action brings any back.
            if firstContact, firstWorkspace == nil {
                var ledger = read.map { planner.baseline($0.snapshot, ledger: ClassicMigrationLedger()) }
                    ?? ClassicMigrationLedger(state: .completed)
                ledger.source = read?.source
                try await save(ledger, to: repository)
                return ClassicMigrationOutcome(decision: .skip(.inUseBefore))
            }
            decision = planner.decision(load, source: read?.source, classicRunning: classicIsRunning(read?.source))
            if case .skip = decision {
                if firstContact { try await save(ClassicMigrationLedger(state: .completed), to: repository) }
                return ClassicMigrationOutcome(decision: decision)
            }
        case .manual:
            decision = .merge
            // A newer cmux-next's ledger is left alone: this build cannot tell what it recorded.
            if case .newer = load { throw ClassicMigrationFailure.newerLedger }
        }
        guard let read else { return ClassicMigrationOutcome(decision: .skip(.noClassicSession)) }
        var ledger: ClassicMigrationLedger
        if case .ledger(let saved) = load { ledger = saved } else { ledger = ClassicMigrationLedger() }
        ledger.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        let store = services.daemon.store
        let live = Set(store.workspaces.map(\.id))
        let liveGroups = Set(store.personal.groups.map(\.id.rawValue))
        let plan = planner.plan(read.snapshot, ledger: ledger, live: live, liveGroups: liveGroups, mode: mode)
        for (key, skip) in plan.skipped where skip == .cloudVM {
            ledger.workspaces[key] = ClassicMigrationLedger.Entry(stage: .skipped, reason: "cloud-vm")
        }
        var outcome = ClassicMigrationOutcome(decision: decision)
        outcome.summary.leftCloudVMs = plan.skipped.values.contains(.cloudVM)
        outcome.summary.alreadyHere = plan.skipped.values.filter { $0 == .alreadyMigrated }.count
        guard !plan.isEmpty else {
            ledger.state = .completed
            ledger.source = read.source
            try await save(ledger, to: repository)
            return outcome
        }

        let preview = ClassicImportPlan(source: read.source, migration: plan)
        guard await confirmation(preview) else {
            outcome.confirmed = false
            return outcome
        }

        // The classic files this run read, copied before anything changes here.
        let stamp = Self.backupStamp()
        try await repository.backup(read.backups, stamp: stamp)
        ledger.state = .inProgress
        ledger.source = read.source
        ledger.runs += 1
        try await save(ledger, to: repository)

        // A cut-off run's half-made workspaces close before they are made again.
        if let connection = services.daemon.connection {
            for half in plan.cleanup {
                guard let key = store.workspace(id: half)?.key else { continue }
                _ = try? await connection.closeWorkspace(key, endTerminals: true)
            }
        }
        let groups = await makeClassicGroups(plan.groups, ledger: &ledger)
        try await save(ledger, to: repository)

        let windows = services.windows
        let firstWindow = firstWorkspace.flatMap { windows.registry.value.owner(of: $0) } ?? windows.active?.state.id
        // Every SSH host starts connecting now, all together. A workspace whose
        // host is not up when its turn comes is made after the local ones, so a
        // host that is off (a laptop away from its network) holds back nothing.
        let knownMachines = Set(services.machines.ssh.map(\.machineID))
        var connecting: [String: DaemonService] = [:]
        for saved in plan.workspaces {
            guard let remote = saved.remote, connecting[remote.sshDestination] == nil else { continue }
            connecting[remote.sshDestination] = try? startClassicDaemon(for: remote)
        }
        let hosts = connecting
        let run = ClassicMigrationRunState(
            ledger: ledger, outcome: outcome, mode: mode, plan: plan, groups: groups, hosts: hosts, repository: repository, progress: progress,
            targets: plan.windows.indices.map { $0 == 0 ? windows.targetWindow(preferring: firstWindow) : UUID().uuidString.lowercased() })

        // One window after another: creating windows side by side was five
        // times slower on the fleet (0.6 against 3 workspaces a second at 512).
        var later: [ClassicWorkspaceTurn] = []
        for index in plan.windows.indices { later += try await makeClassicWindow(index, run: run) }
        if !later.isEmpty {
            // The hosts still connecting, waited for together (each within its connect limit).
            let waiting = Set(later.compactMap { $0.saved.remote?.sshDestination })
            let waits = waiting.compactMap { destination in
                hosts[destination].map { daemon in Task { @MainActor in (destination, (try? await self.connected(daemon)) != nil) } }
            }
            for wait in waits {
                let (destination, up) = await wait.value
                guard !up else { continue }
                run.unreachable.insert(destination)
                // A machine this run added and that never connected is not left in the list.
                if let daemon = hosts[destination], !knownMachines.contains(daemon.machineID),
                   let session = services.machines.sshSession(daemon.machineID) {
                    await services.ssh.forget(session)
                }
            }
            for turn in later.sorted(by: { $0.index < $1.index }) { try await makeClassicWorkspace(turn.saved, window: turn.index, run: run) }
        }
        ledger = run.ledger
        outcome = run.outcome
        let lastError = run.lastError, reveal = run.reveal, openedInFirstWindow = run.openedInFirstWindow
        ledger.state = .completed
        try await save(ledger, to: repository)
        // One workspace that did not open is logged; none opening is the run's failure.
        if outcome.opened.isEmpty, let lastError { throw lastError }
        // Set within the run, so whoever awaits the run reads it.
        if mode == .automatic, !outcome.opened.isEmpty { owner.classicImportNotice = ClassicImportStrings.notice(outcome.summary) }

        if let reveal { _ = windows.reveal(workspaceID: reveal) }
        // The New Tab page launch made for an empty tree gives way to classic's workspaces. A first
        // launch that landed on Home (FirstWorkspaceLaunch) made none: Home stays.
        if openedInFirstWindow, let firstWorkspace, let made = store.workspace(id: firstWorkspace), made.kind != "home",
           let key = made.key, let connection = services.daemon.connection {
            _ = try? await connection.closeWorkspace(key, endTerminals: true, ifEmpty: false)
        }
        return outcome
    }

    /// One classic window's workspaces, in order; returns the SSH ones whose
    /// host was not up at their turn, for after the local ones.
    fileprivate func makeClassicWindow(_ index: Int, run: ClassicMigrationRunState) async throws -> [ClassicWorkspaceTurn] {
        var waiting: [ClassicWorkspaceTurn] = []
        for saved in run.plan.windows[index].workspaces {
            if let remote = saved.remote, let host = run.hosts[remote.sshDestination], host.connection == nil {
                waiting.append(ClassicWorkspaceTurn(index: index, saved: saved))
                continue
            }
            try await makeClassicWorkspace(saved, window: index, run: run)
        }
        return waiting
    }

    /// Makes one classic workspace, recording it in the ledger before, while and after.
    fileprivate func makeClassicWorkspace(_ saved: ClassicSessionWorkspace, window index: Int, run: ClassicMigrationRunState) async throws {
        defer { run.handled() }
        let window = run.plan.windows[index]
        let frame = index == 0 ? nil : window.frame.flatMap(Self.onScreen)
        let repository = run.repository
        run.ledger.workspaces[saved.key] = ClassicMigrationLedger.Entry(stage: .pending)
        try await save(run.ledger, to: repository)
        var made: String?
        // This call's own copies, merged after: nothing holds the run's state across a suspension.
        var summary = ClassicImportSummary()
        var unreachable = run.unreachable
        defer {
            run.outcome.summary.merge(summary)
            run.unreachable.formUnion(unreachable)
        }
        do {
            made = try await importClassicWorkspace(saved, into: run.targets[index], frame: frame, summary: &summary,
                                                    unreachable: &unreachable,
                                                    on: saved.remote.flatMap { run.hosts[$0.sshDestination] }) { id in
                run.ledger.workspaces[saved.key] = ClassicMigrationLedger.Entry(stage: .created, nextWorkspace: id)
                try? await self.save(run.ledger, to: repository)
            }
        } catch {
            // Stays pending with its half-made workspace: the next manual run closes and remakes it.
            run.lastError = error
            run.outcome.failures[saved.key] = String(describing: error)
            return
        }
        // Nothing came over (an SSH host that did not connect): the next manual run tries again.
        guard let made else { return }
        await applyClassicIdentity(saved, to: made, groups: run.groups)
        run.ledger.workspaces[saved.key] = ClassicMigrationLedger.Entry(stage: .done, nextWorkspace: made)
        try await save(run.ledger, to: repository)
        run.outcome.opened.append(made)
        // The launch's run only: Import from Classic is the person asking now, its terminals open live.
        if run.mode == .automatic, saved.key != window.selectedKey { await parkClassicTerminals(of: made, saved: saved) }
        if index == 0 { run.openedInFirstWindow = true }
        if index == 0, saved.key == window.selectedKey { run.reveal = made }
    }

    /// Parks the terminals of a workspace that came over in the background
    /// (`park-tabs`): their shells end and their tabs stay, each starting when
    /// the workspace is first shown (`DaemonService.wakeParkedTabs`). So a
    /// session with more terminals than macOS has PTYs (`kern.tty.ptmx_max`)
    /// comes over whole. A workspace whose classic terminals carry scrollback
    /// keeps running: its shell prints the scrollback at its first prompt.
    private func parkClassicTerminals(of id: String, saved: ClassicSessionWorkspace) async {
        let local = services.machines.local
        guard local.supports(DaemonCapability.tabPark.rawValue), local.supports(DaemonCapability.tabRestartKeptLayout.rawValue),
              saved.remote == nil, !saved.layout.tabs.contains(where: { $0.scrollback != nil || $0.agent != nil }),
              let connection = local.connection else { return }
        let store = local.store
        let terminals: @MainActor @Sendable () -> [SurfaceID] = {
            store.workspace(id: id)?.screens.flatMap(\.panes).flatMap(\.tabs).filter { $0.kind == .pty && !$0.dead }.map(\.surface) ?? []
        }
        let expected = saved.layout.tabs.filter { $0.url == nil }.count
        guard expected > 0, await Self.awaitStore({ terminals().count >= expected }) else { return }
        do {
            _ = try await connection.request(ParkTabsRequest(surfaces: terminals()))
        } catch {
            services.daemon.logger.error("classic workspace not parked: \(String(describing: error), privacy: .public)")
        }
    }

    /// Whether `ready` holds, now or within 5 s, woken by the store's own changes.
    private static func awaitStore(_ ready: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        if ready() { return true }
        let outcome = FirstOutcome<Bool>()
        let watch = Task { @MainActor in
            for await done in ObservationStream(ready) where done {
                outcome.resolve(true)
                return
            }
        }
        // A bounded wait: the daemon's event normally lands within one turn.
        let bound = DemandTimer(owner: "ClassicMigration.awaitStore")
        bound.schedule(after: .seconds(5)) { outcome.resolve(false) }
        let done = await outcome.value()
        watch.cancel()
        bound.cancel()
        return done || ready()
    }

    fileprivate func save(_ ledger: ClassicMigrationLedger, to repository: ClassicMigrationRepository) async throws {
        var ledger = ledger
        ledger.updatedAt = Date().timeIntervalSince1970
        try await repository.save(ledger)
    }

    /// Classic's session: the test's file when set, else the channel the
    /// finder picks, trying its session file, `-previous` copy and newest
    /// archive in turn until one decodes.
    private func readClassicSnapshot() async throws -> ClassicSnapshotRead? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let finder = ClassicMigrationSourceFinder(support: owner.classicMigrationSupport ?? support,
                                                  ownBundleID: services.environment.launch.bundleID)
        let candidates: [(url: URL, bundleID: String)]
        if let seam = owner.classicSessions { candidates = [(seam.fileURL, ClassicSessionImporter.stableBundleIdentifier)] }
        else { candidates = finder.candidates() }
        var lastError: (any Error)?
        for candidate in candidates {
            let importer = ClassicSessionImporter(fileURL: candidate.url)
            do {
                let snapshot = try await Task.detached { try importer.readSnapshot() }.value
                guard let snapshot else { continue }
                let opened = Self.openingMissingFolders(snapshot)
                guard let source = finder.source(candidate.url, bundleID: candidate.bundleID, createdAt: snapshot.createdAt) else { continue }
                let siblings = candidates.map(\.url).filter { $0 != candidate.url }
                return ClassicSnapshotRead(snapshot: opened, source: source, backups: [candidate.url] + siblings)
            } catch {
                // A damaged or oversized file: the next copy may still read.
                lastError = error
                services.daemon.logger.error("classic session not read: \(String(describing: error), privacy: .public)")
            }
        }
        if let lastError, candidates.count == 1 { throw lastError }
        return nil
    }

    /// Local folders that are gone open the home folder (`readForImport`), window by window.
    private nonisolated static func openingMissingFolders(_ snapshot: ClassicSessionSnapshot) -> ClassicSessionSnapshot {
        let exists: (String) -> Bool = { path in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
        }
        let windows = snapshot.windows.map { window in
            ClassicSessionWindow(id: window.id, frame: window.frame, selectedWorkspace: window.selectedWorkspace,
                                 workspaces: window.workspaces.map { saved in
                                     guard saved.remote == nil, saved.cloudVM == nil else { return saved }
                                     return saved.openingMissingFolders(in: NSHomeDirectory(), exists: exists)
                                 }, groups: window.groups)
        }
        return ClassicSessionSnapshot(version: snapshot.version, createdAt: snapshot.createdAt, windows: windows)
    }

    /// Makes the plan's new groups (reusing ones an earlier run made) and
    /// returns cmux-next group ids by classic group id. Needs the daemon's
    /// state resources; on an older daemon workspaces come over loose.
    private func makeClassicGroups(_ groups: [ClassicMigrationPlan.Group],
                                   ledger: inout ClassicMigrationLedger) async -> [String: WorkspaceGroupID] {
        var made: [String: WorkspaceGroupID] = [:]
        let local = services.machines.local
        guard let connection = local.connection, local.store.servesStateResources else { return [:] }
        for group in groups {
            if let existing = group.existing {
                made[group.classic.id] = WorkspaceGroupID(rawValue: existing)
                continue
            }
            do {
                let name = SidebarGroup.named(group.classic.name)
                let id = try await connection.state.createWorkspaceGroup(name: name, room: nil, color: group.classic.color).id
                ledger.groups[group.classic.id] = id
                made[group.classic.id] = WorkspaceGroupID(rawValue: id)
                let icon = local.supports(DaemonCapability.workspaceGroupIcon.rawValue) ? group.classic.icon : nil
                let pinned: Bool? = local.supports(DaemonCapability.workspaceGroupPin.rawValue) && group.classic.pinned ? true : nil
                if group.classic.collapsed || icon != nil || pinned != nil {
                    try await connection.state.updateWorkspaceGroup(id, collapsed: group.classic.collapsed ? true : nil,
                                                                    icon: icon.map { .set($0) } ?? .unchanged, pinned: pinned)
                }
            } catch {
                services.daemon.logger.error("classic group not made: \(String(describing: error), privacy: .public)")
            }
        }
        return made
    }

    /// The workspace's classic color, pin and group, on its new cmux-next workspace.
    fileprivate func applyClassicIdentity(_ saved: ClassicSessionWorkspace, to id: String, groups: [String: WorkspaceGroupID]) async {
        let local = services.machines.local
        let store = local.store
        // The create returns before the store mirrors the new workspace: its look would be dropped.
        guard await Self.awaitStore({ store.workspace(id: id)?.key != nil }),
              let connection = local.connection, let key = store.workspace(id: id)?.key else {
            services.daemon.logger.error("classic workspace look not kept: \(id, privacy: .public) never showed")
            return
        }
        do {
            if let color = saved.color {
                try await connection.state.setWorkspaceIdentity(key, resource: store.stateResourceID(workspace: key), color: .set(color))
            }
            if saved.pinned, local.supports(DaemonCapability.workspacePin.rawValue) {
                _ = try await connection.setWorkspaceMetadata(key, pinned: true)
            }
            if let classic = saved.groupID, let group = groups[classic], let session = store.registryID {
                try await connection.state.placePersonalWorkspace(session: session, key: key,
                                                                  resource: store.personalStateID(session: session, key: key),
                                                                  group: .set(group))
            }
        } catch {
            services.daemon.logger.error("classic workspace look not kept: \(String(describing: error), privacy: .public)")
        }
    }

    /// Whether classic cmux is running and may still save (``ClassicRunningProbe``:
    /// its launch sentinel and a recent save). No process scan (plans/cmux-next/pty-holder.md).
    private func classicIsRunning(_ source: ClassicMigrationSource?) -> Bool {
        if let seam = owner.classicRunning { return seam() }
        guard let source else { return false }
        let root = owner.classicStateRoot ?? ClassicRunningProbe.defaultStateRoot(
            home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment)
        return ClassicRunningProbe(stateRoot: root).isRunning(source, now: Date().timeIntervalSince1970)
    }

    /// `frame` when some screen shows most of it, else nil (the window opens at the default place).
    private static func onScreen(_ frame: CGRect) -> CGRect? {
        NSScreen.screens.contains { $0.visibleFrame.intersection(frame).width >= min(200, frame.width) } ? frame : nil
    }

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(4).lowercased()
    }
}

private enum ClassicMigrationFailure: Error {
    /// A newer cmux-next wrote the ledger; this build leaves it alone.
    case newerLedger
}

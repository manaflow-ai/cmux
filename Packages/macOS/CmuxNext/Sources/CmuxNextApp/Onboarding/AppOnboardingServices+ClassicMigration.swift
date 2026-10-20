import AppKit
import CmuxNextBridge
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
    /// - Parameter firstWorkspace: the New Tab page workspace launch made for
    ///   an empty tree; closed when the migration brought workspaces into its window.
    func migrateClassicAtLaunch(firstWorkspace: String?) async {
        guard classicMigrationRunsAtLaunch else { return }
        do {
            let outcome = try await migrateClassic(.automatic, firstWorkspace: firstWorkspace)
            guard !outcome.opened.isEmpty, let notice = owner.classicImportNotice else { return }
            ClassicImportStrings.toast(notice, in: services.windows.active?.window)
        } catch {
            services.daemon.logger.error("classic migration failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// One migration run. Runs never overlap: a second one waits for the first.
    func migrateClassic(_ mode: ClassicMigrationPlanner.Mode, firstWorkspace: String? = nil) async throws -> ClassicMigrationOutcome {
        let previous = owner.classicMigrationRun
        let run = Task { @MainActor in
            _ = await previous?.result
            return try await runClassicMigration(mode, firstWorkspace: firstWorkspace)
        }
        owner.classicMigrationRun = run
        return try await run.value
    }

    private func runClassicMigration(_ mode: ClassicMigrationPlanner.Mode, firstWorkspace: String?) async throws -> ClassicMigrationOutcome {
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
            ledger: ledger, outcome: outcome, plan: plan, groups: groups, hosts: hosts, repository: repository,
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
        await placeClassicWorkspaces(plan, made: run.made, ledger: run.ledger, targets: run.targets)
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
        // The New Tab page launch made for an empty tree gives way to classic's workspaces.
        if openedInFirstWindow, let firstWorkspace, let key = store.workspace(id: firstWorkspace)?.key,
           let connection = services.daemon.connection {
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
        run.made[index, default: []].insert(made)
        if index == 0 { run.openedInFirstWindow = true }
        if index == 0, saved.key == window.selectedKey { run.reveal = made }
    }

    /// Puts the workspaces this run made at their classic place in each
    /// window's sidebar, through the row-drag path (`SidebarBridge.place`):
    /// a resumed or merged run makes them last. In each sidebar container
    /// (the pinned rows, the loose rows, a group) each one goes right below
    /// the nearest classic workspace before it there, else right above the
    /// next one. One already in place does not move, so a first run moves
    /// nothing and the person's own order of earlier ones stays.
    private func placeClassicWorkspaces(_ plan: ClassicMigrationPlan, made: [Int: Set<String>], ledger: ClassicMigrationLedger,
                                        targets: [String]) async {
        let machines = services.machines
        let registry = services.windows.registry
        for (index, window) in plan.windows.enumerated() {
            guard let fresh = made[index], !fresh.isEmpty,
                  let bridge = services.windows.controller(for: targets[index])?.sidebar else { continue }
            let target = targets[index]
            // The window's sidebar as the store has it now (the same rows the person's sidebar draws).
            let sections: @MainActor @Sendable () -> [SidebarRowSection] = {
                SidebarBridge.sections(machines, members: registry.members(of: target), profile: .defaultProfile)
            }
            let listed: @MainActor @Sendable () -> Set<String> = {
                Set(sections().flatMap(\.nodes).flatMap(Self.workspaceIDs))
            }
            guard await Self.awaitStore({ fresh.isSubset(of: listed()) }) else { continue }
            // Classic's window as it is here, in classic's order (what earlier runs made too).
            let classic = window.workspaces.compactMap { ledger.workspaces[$0.key]?.nextWorkspace }
            for id in classic where fresh.contains(id) {
                let now = sections()
                guard let (section, container) = Self.container(of: id, in: now) else { continue }
                let mates = classic.filter(container.contains)
                guard let at = mates.firstIndex(of: id) else { continue }
                let shown = container.filter(mates.contains)
                let before = at > 0 ? mates[at - 1] : nil
                let after = at + 1 < mates.count ? mates[at + 1] : nil
                let current = shown.firstIndex(of: id)
                let inPlace = before.map { shown.firstIndex(of: $0).map { $0 + 1 } == current }
                    ?? after.map { shown.firstIndex(of: $0).map { $0 - 1 } == current } ?? true
                guard !inPlace else { continue }
                let slot: WorkspaceSlot? = before.map { .below($0) } ?? after.map { .above($0) }
                guard let slot, let drop = slot.position(moving: [id], section: section, in: now) else { continue }
                bridge.place([SidebarWorkspaceID(id)], at: drop, in: now)
                // The next one is placed against the sidebar with this one moved.
                _ = await Self.awaitStore({ Self.container(of: id, in: sections()).map { _, rows in
                    before.map { b in rows.firstIndex(of: b).map { $0 + 1 } == rows.firstIndex(of: id) }
                        ?? after.map { a in rows.firstIndex(of: a).map { $0 - 1 } == rows.firstIndex(of: id) } ?? true
                } ?? false })
            }
        }
    }

    /// The workspace ids a sidebar node lists.
    private nonisolated static func workspaceIDs(_ node: SidebarNode) -> [String] {
        switch node {
        case .workspace(let workspace): [workspace.id.rawValue]
        case .group(let group): group.workspaces.map(\.id.rawValue)
        case .item: []
        }
    }

    /// The section and the container (its loose rows, or one group's rows) that list `id`, rows in order.
    private nonisolated static func container(of id: String, in sections: [SidebarRowSection]) -> (SectionID, [String])? {
        for section in sections {
            let loose = section.nodes.compactMap { node -> String? in
                if case .workspace(let workspace) = node { return workspace.id.rawValue }
                return nil
            }
            if loose.contains(id) { return (section.id, loose) }
            for case .group(let group) in section.nodes {
                let rows = group.workspaces.map(\.id.rawValue)
                if rows.contains(id) { return (section.id, rows) }
            }
        }
        return nil
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
                let icon = local.supports(DaemonCapabilities.shared.workspaceGroupIcon) ? group.classic.icon : nil
                let pinned: Bool? = local.supports(DaemonCapabilities.shared.workspaceGroupPin) && group.classic.pinned ? true : nil
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
            if saved.pinned, local.supports(DaemonCapabilities.shared.workspacePin) {
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

/// A classic workspace and the index of the classic window it belongs to.
fileprivate struct ClassicWorkspaceTurn: Sendable {
    var index: Int
    var saved: ClassicSessionWorkspace
}

/// One run's state, which each workspace it makes writes.
@MainActor
fileprivate final class ClassicMigrationRunState {
    var ledger: ClassicMigrationLedger
    var outcome: ClassicMigrationOutcome
    let plan: ClassicMigrationPlan
    /// cmux-next group ids by classic group id.
    let groups: [String: WorkspaceGroupID]
    /// The daemon of each SSH destination, connecting since the run's start.
    let hosts: [String: DaemonService]
    let repository: ClassicMigrationRepository
    /// The window each classic window's workspaces go to, by index.
    let targets: [String]
    var unreachable = Set<String>()
    var lastError: (any Error)?
    var reveal: String?
    var openedInFirstWindow = false
    /// cmux-next workspaces made in this run, by classic window index.
    var made: [Int: Set<String>] = [:]

    init(ledger: ClassicMigrationLedger, outcome: ClassicMigrationOutcome, plan: ClassicMigrationPlan,
         groups: [String: WorkspaceGroupID], hosts: [String: DaemonService], repository: ClassicMigrationRepository, targets: [String]) {
        self.ledger = ledger
        self.outcome = outcome
        self.plan = plan
        self.groups = groups
        self.hosts = hosts
        self.repository = repository
        self.targets = targets
    }
}

/// Classic's session as read, the save it came from, and the files to back up.
private struct ClassicSnapshotRead {
    var snapshot: ClassicSessionSnapshot
    var source: ClassicMigrationSource
    var backups: [URL]
}

private enum ClassicMigrationFailure: Error {
    /// A newer cmux-next wrote the ledger; this build leaves it alone.
    case newerLedger
}

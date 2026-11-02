import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextOnboarding
import Foundation
import Testing

/// Simulated classic cmux users upgrading to cmux-next, end to end on the real
/// daemon (``ClassicUpgradeSimulator``). Each profile (``ClassicUpgradeProfile``)
/// is one kind of person: fresh, small, many groups, deep splits, browsers and
/// viewers, several windows, classic's oldest schema, a damaged session. Then
/// the paths around the first launch: a relaunch, the import action, classic
/// still running, a damaged file with a good copy, a run cut off midway, a
/// downgrade and re-upgrade, an SSH host that is off.
///
/// Every launch is the Sparkle update relaunch: classic saved seconds ago, on
/// quit, and removed its launch sentinel. Timing lines start with
/// `CLASSIC-SIM` for the fleet log.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ClassicUpgradeSimulationTests {
    /// The first window shows before the migration's work, whatever classic held.
    static let firstWindowBudget: Duration = .seconds(10)

    private static func report(_ name: String, _ launch: ClassicUpgradeSimulator.Launch, workspaces: Int) {
        print(String(format: "CLASSIC-SIM %@ workspaces=%d first_window=%.2fs migration=%.2fs per_workspace=%.0fms decision=%@",
                     name, workspaces, launch.firstWindow.simSeconds, launch.migration.simSeconds,
                     workspaces == 0 ? 0 : launch.migration.simSeconds * 1000 / Double(workspaces),
                     String(describing: launch.outcome?.decision ?? .skip(.disabled))))
    }

    /// The matrix: the first launch brings everything once; relaunching and the
    /// import action make nothing more.
    @Test(arguments: ["fresh", "small", "manyGroups", "nestedSplits", "browsersAndViewers", "multiWindow", "oldSchema", "messy"])
    func theFirstLaunchBringsEverythingOnce(_ name: String) async throws {
        let profile = try #require(ClassicUpgradeProfile.matrix.first { $0.name == name })
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let before = try mac.classicDigest()
        let sim = try ClassicUpgradeSimulator(mac: mac)
        let launch = await sim.launch()
        #expect(launch.failure == nil, "\(String(describing: launch.failure))")
        #expect(launch.outcome?.decision == .firstRun, "\(String(describing: launch.outcome))")
        await sim.settle()
        try sim.verify(profile, classicBefore: before)

        let again = try await sim.relaunch()
        #expect(again.decision == .skip(.unchanged) && again.opened.isEmpty, "\(again)")
        let manual = try await sim.manualImport()
        #expect(manual.opened.isEmpty, "\(manual)")
        await sim.settle()
        try sim.verify(profile, classicBefore: before)
        await sim.shutdown()
    }

    /// Classic runs beside cmux-next (both installed): nothing comes over while
    /// it may still save. Once it quits and saved, the next launch brings all of it.
    @Test func whileClassicRunsNothingComesThenItsQuitSaveMigrates() async throws {
        let profile = ClassicUpgradeProfile.small
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.classicRunning(true)
        try mac.save(profile)
        let sim = try ClassicUpgradeSimulator(mac: mac)
        let launch = await sim.launch()
        #expect(launch.outcome?.decision == .skip(.classicRunning), "\(String(describing: launch.outcome))")
        // Only the launch's own New Tab page: none of classic's.
        let own = Set(sim.made().keys)
        #expect(own.count <= 1, "\(sim.made().values.map(\.name))")
        // Classic quits: its quit save is newer, its sentinel gone.
        try mac.classicRunning(false)
        var saved = profile
        saved.createdAt += 60
        try mac.save(saved)
        let before = try mac.classicDigest()
        let merge = try await sim.relaunch()
        #expect(merge.decision == .merge && merge.opened.count == profile.expectedCount, "\(merge)")
        // The New Tab page from the first launch is the person's now; it stays.
        await sim.settle()
        try sim.verify(saved, classicBefore: before, ignoring: own)
        await sim.shutdown()
    }

    /// The session file is damaged (cut off mid-write): its `-previous` copy comes over, once.
    @Test func aDamagedSessionFallsBackToItsPreviousCopy() async throws {
        let profile = ClassicUpgradeProfile.small
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile, suffix: "-previous")
        try Data("{\"version\":1,\"windows\":[{\"tabManager\":{\"workspaces\":[{\"stab".utf8).write(to: mac.session())
        let before = try mac.classicDigest()
        let sim = try ClassicUpgradeSimulator(mac: mac)
        let launch = await sim.launch()
        #expect(launch.outcome?.decision == .firstRun, "\(String(describing: launch.outcome))")
        await sim.settle()
        try sim.verify(profile, classicBefore: before, source: mac.session(suffix: "-previous"))
        #expect(try await sim.relaunch().opened.isEmpty)
        await sim.shutdown()
    }

    /// The session file and its copy are damaged: the newest archive comes over.
    @Test func bothDamagedFallsBackToTheNewestArchive() async throws {
        let profile = ClassicUpgradeProfile.nestedSplits
        let mac = try ClassicUpgradeSimulator.Mac()
        let history = mac.classic.appendingPathComponent("session-history", isDirectory: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let older = history.appendingPathComponent("session-com.cmuxterm.app-1891000000000-w1-p1.json")
        let newest = history.appendingPathComponent("session-com.cmuxterm.app-1891000500000-w1-p4.json")
        try ClassicUpgradeProfile.fresh.sessionData(home: mac.home).write(to: older)
        try profile.sessionData(home: mac.home).write(to: newest)
        try Data("garbage".utf8).write(to: mac.session())
        try Data("[1,2]".utf8).write(to: mac.session(suffix: "-previous"))
        let before = try mac.classicDigest()
        let sim = try ClassicUpgradeSimulator(mac: mac)
        _ = await sim.launch()
        await sim.settle()
        try sim.verify(profile, classicBefore: before, source: newest)
        await sim.shutdown()
    }

    /// Classic's session file is gone and only its `-previous` copy is left.
    @Test func onlyThePreviousCopyLeftStillMigrates() async throws {
        let profile = ClassicUpgradeProfile.multiWindow
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile, suffix: "-previous")
        let before = try mac.classicDigest()
        let sim = try ClassicUpgradeSimulator(mac: mac)
        let launch = await sim.launch()
        #expect(launch.outcome?.decision == .firstRun, "\(String(describing: launch.outcome))")
        await sim.settle()
        try sim.verify(profile, classicBefore: before, source: mac.session(suffix: "-previous"))
        await sim.shutdown()
    }

    /// The app quit midway (crash, power, Force Quit): two workspaces were
    /// half made, one about to be. The next launch finishes, each once.
    @Test func aRunCutOffMidwayFinishesWithoutDuplicates() async throws {
        let profile = ClassicUpgradeProfile.manyGroups
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let before = try mac.classicDigest()
        let sim = try ClassicUpgradeSimulator(mac: mac)
        _ = await sim.launch()
        var ledger = try mac.readLedger()
        let keys = ledger.workspaces.filter { $0.value.stage == .done }.keys.sorted()
        try #require(keys.count >= 3)
        ledger.state = .inProgress
        ledger.workspaces[keys[0]]?.stage = .created
        ledger.workspaces[keys[1]]?.stage = .created
        ledger.workspaces[keys[2]] = ClassicMigrationLedger.Entry(stage: .pending)
        // The third one's workspace is gone too: the cut came before it was made.
        if let id = try mac.readLedger().workspaces[keys[2]]?.nextWorkspace, let key = sim.services.daemon.store.workspace(id: id)?.key {
            _ = try await sim.services.daemon.connection?.closeWorkspace(key, endTerminals: true)
        }
        try JSONEncoder().encode(ledger).write(to: mac.ledger, options: .atomic)
        let resume = try await sim.relaunch()
        #expect(resume.decision == .resume && resume.opened.count == 3, "\(resume)")
        await sim.settle()
        // Open: the remade workspaces come back at the end of their container, not at their classic place.
        try sim.verify(profile, classicBefore: before, orderIsKnownIssue: true)
        await sim.shutdown()
    }

    /// Downgrade to classic, which made workspaces (one in a new group, one in
    /// an old one), then upgrade again: only those come over, into the right groups.
    @Test func aDowngradeAndReUpgradeMergesOnlyNewWork() async throws {
        let profile = ClassicUpgradeProfile.small
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let sim = try ClassicUpgradeSimulator(mac: mac)
        _ = await sim.launch()
        var later = profile
        later.createdAt += 3600
        later.windows[0].groups.append(ClassicUpgradeProfile.Group(id: "G-NEW", name: "Made in classic", collapsed: true))
        let added: [ClassicUpgradeProfile.Workspace] = [
            ClassicUpgradeProfile.Workspace(title: "new loose"),
            ClassicUpgradeProfile.Workspace(title: "new in old group", group: "G-WORK"),
            ClassicUpgradeProfile.Workspace(title: "new in new group", group: "G-NEW"),
        ]
        later.windows[0].workspaces.append(contentsOf: added)
        try mac.save(later)
        let before = try mac.classicDigest()
        let merge = try await sim.relaunch()
        #expect(merge.decision == .merge && merge.opened.count == 3, "\(merge)")
        await sim.settle()
        try sim.verify(later, classicBefore: before)
        await sim.shutdown()
    }

    /// The import action runs while the launch's run is still going: runs take
    /// turns, nothing is made twice.
    @Test func theImportActionDuringTheLaunchRunMakesNothingTwice() async throws {
        let profile = ClassicUpgradeProfile.manyGroups
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let before = try mac.classicDigest()
        let sim = try ClassicUpgradeSimulator(mac: mac)
        let services = sim.services
        let manual = Task { @MainActor in
            while services.onboarding.classicMigrationRun == nil { try? await Task.sleep(for: .milliseconds(10)) }
            return try await AppOnboardingServices(owner: services.onboarding)
                .migrateClassic(.manual) { _ in true }
        }
        _ = await sim.launch()
        _ = try await manual.value
        _ = try await services.onboarding.classicMigrationRun?.value
        await sim.settle()
        try sim.verify(profile, classicBefore: before)
        await sim.shutdown()
    }

    /// An SSH workspace whose host is off (a laptop away from its network):
    /// the local workspaces come over at once, not after its 20 s connect limit.
    @Test func anOffSSHHostDoesNotHoldBackLocalWorkspaces() async throws {
        typealias Workspace = ClassicUpgradeProfile.Workspace
        let workspaces: [Workspace] = [
            Workspace(title: "remote a", ssh: "dev@offline-a.invalid", stays: true),
            Workspace(title: "local 1"), Workspace(title: "local 2"),
            Workspace(title: "remote b", ssh: "dev@offline-b.invalid", stays: true),
            Workspace(title: "local 3"),
        ]
        let profile = ClassicUpgradeProfile(name: "sshOff", windows: [ClassicUpgradeProfile.Window(workspaces: workspaces)])
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let before = try mac.classicDigest()
        let sim = try ClassicUpgradeSimulator(mac: mac)
        let launch = await sim.launch()
        Self.report(profile.name, launch, workspaces: 3)
        // Not held back: every local workspace showed before the run took up either SSH one, which it
        // does only after their hosts' connect limit (the ledger records a workspace's turn first). An
        // event order, not a wall-clock budget, so it holds on a loaded runner.
        let decoded = try ClassicSessionImporter(fileURL: mac.session()).decodeSnapshot(Data(contentsOf: mac.session()))
        let remoteTurns = decoded.windows.flatMap(\.workspaces).filter { $0.remote != nil }.compactMap { sim.ledgered[$0.key] }
        #expect(remoteTurns.count == 2, "SSH workspaces' turns: \(remoteTurns)")
        for name in ["local 1", "local 2", "local 3"] {
            let at = try #require(sim.appeared[name], "\(name) never showed")
            #expect(remoteTurns.allSatisfy { at <= $0 }, "\(name) showed at \(at) s, after an SSH workspace's turn at \(remoteTurns) s")
        }
        #expect(launch.outcome?.summary.leftSSH == true, "\(String(describing: launch.outcome))")
        await sim.settle()
        try sim.verify(profile, classicBefore: before)
        await sim.shutdown()
    }

    /// The sidebar placements a run asks for go through one queue, each after
    /// the one before it is applied (#26153). On a loaded runner that queue
    /// trails the run, and the tree sat still for the settle window while
    /// placements were still waiting: the check then read the daemon's own
    /// order, not classic's (the base red at :45, :129, :206 and :253). Here a
    /// placement ahead of the run holds the queue for a while, as a slow one
    /// does there; the check reads the order only once the queue is through.
    @Test func theOrderIsReadOnlyOnceQueuedPlacementsLand() async throws {
        let profile = ClassicUpgradeProfile.small
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let before = try mac.classicDigest()
        let sim = try ClassicUpgradeSimulator(mac: mac)
        // Held longer than the settle window, from before the run places anything.
        sim.services.personalPlacements.enqueue(on: sim.services.daemon, failed: {}) {
            try? await Task.sleep(for: .seconds(4))
            return .skipped
        }
        _ = await sim.launch()
        await sim.settle()
        try sim.verify(profile, classicBefore: before)
        await sim.shutdown()
    }

    /// Background workspaces come over parked: their tabs stay, their shells
    /// do not run (no PTY), and showing one starts its terminals in place.
    @Test func backgroundWorkspacesStartTheirTerminalsWhenFirstShown() async throws {
        let profile = ClassicUpgradeProfile.small
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let before = try mac.classicDigest()
        let sim = try ClassicUpgradeSimulator(mac: mac)
        _ = await sim.launch()
        await sim.settle()
        try sim.verify(profile, classicBefore: before)
        let store = sim.services.daemon.store
        let ledger = try mac.readLedger()
        let decoded = try ClassicSessionImporter(fileURL: mac.session()).decodeSnapshot(Data(contentsOf: mac.session()))
        let selected = decoded.windows[0].selectedWorkspace.map { decoded.windows[0].workspaces[$0].key }
        let background = decoded.windows[0].workspaces.filter { $0.key != selected }.compactMap { ledger.workspaces[$0.key]?.nextWorkspace }
        try #require(!background.isEmpty)
        let tabs = { (id: String) in store.workspace(id: id)?.screens.flatMap(\.panes).flatMap(\.tabs).filter { $0.kind == .pty } ?? [] }
        // `park-tabs` answers before the shells exit: a tab shows dead with `relaunch` once its host exited, a
        // moment after the run's last park (the quiet window settle() had covered that by chance). Read once
        // every one has (the daemon's tab-exit events), with a ceiling for a hang, not a budget.
        let parked = { (id: String) in !tabs(id).isEmpty && tabs(id).allSatisfy { $0.dead && $0.relaunch?.onShow == true } }
        let parkDeadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < parkDeadline, !background.allSatisfy(parked) { try? await Task.sleep(for: .milliseconds(20)) }
        for id in background {
            #expect(parked(id),
                    "\(store.workspace(id: id)?.name ?? id) is not parked: \(tabs(id).map { ($0.dead, $0.relaunch?.onShow) })")
        }
        // Shown: its terminals start, in the same tabs.
        let shown = background[0]
        let surfaces = tabs(shown).map(\.surface)
        let window = try #require(sim.services.windows.registry.value.owner(of: shown).flatMap { sim.services.windows.controller(for: $0) })
        window.state.showWorkspace(shown)
        let clock = ContinuousClock()
        // A ceiling for the shells to start, not a budget.
        let deadline = clock.now + .seconds(60)
        while clock.now < deadline, tabs(shown).contains(where: \.dead) { try? await Task.sleep(for: .milliseconds(100)) }
        #expect(tabs(shown).allSatisfy { !$0.dead }, "\(tabs(shown).map { ($0.dead, $0.relaunch) })")
        #expect(tabs(shown).map(\.surface) == surfaces)
        // The others stay parked.
        for id in background.dropFirst() { #expect(tabs(id).allSatisfy { $0.dead }) }
        await sim.shutdown()
    }
}


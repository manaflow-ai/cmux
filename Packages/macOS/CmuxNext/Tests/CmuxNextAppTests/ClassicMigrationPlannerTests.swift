import CmuxNextOnboarding
import Foundation
import Testing

/// The classic migration's rules without a daemon: what is read from a classic
/// session (windows, groups, keys, colors, pins), whether a launch runs, and
/// what a run makes (classic-migration-DESIGN.md, edge-case table).
///
/// Fixture `tests/fixtures/classic-to-next/session-groups.json`: classic
/// 0.64.19's split-workspace session, extended by hand in classic's schema
/// (`SessionPersistence.swift`) with a second window, two groups (one
/// collapsed with color and icon, one pinned and empty), a colored grouped
/// workspace, a pinned one, a Cloud VM workspace, and a `stableId` saved twice.
@Suite struct ClassicMigrationPlannerTests {
    static let fixture: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("tests/fixtures/classic-to-next/session-groups.json")
    }()

    static let backend = "11111111-1111-4111-8111-111111111111"
    static let saved = "22222222-2222-4222-8222-222222222222"
    static let home = "AAAAAAAA-0000-4000-8000-000000000001"
    static let split = "AAAAAAAA-0000-4000-8000-000000000002"
    static let pinned = "AAAAAAAA-0000-4000-8000-000000000003"
    static let cloud = "AAAAAAAA-0000-4000-8000-000000000004"
    static let second = "AAAAAAAA-0000-4000-8000-000000000005"

    private func snapshot(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> ClassicSessionSnapshot {
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as? [String: Any])
        edit(&root)
        return try ClassicSessionImporter(fileURL: Self.fixture).decodeSnapshot(JSONSerialization.data(withJSONObject: root))
    }

    private func source(createdAt: Double, bundle: String = "com.cmuxterm.app") -> ClassicMigrationSource {
        ClassicMigrationSource(path: "/s/session-\(bundle).json", bundleID: bundle, size: 10, modifiedAt: createdAt, createdAt: createdAt)
    }

    /// A ledger as a finished run leaves it: every planned workspace done.
    private func finished(_ plan: ClassicMigrationPlan, groups: [String: String] = [:], at: Double = 1) -> ClassicMigrationLedger {
        var ledger = ClassicMigrationLedger(state: .completed, source: source(createdAt: at), groups: groups)
        for (index, workspace) in plan.workspaces.enumerated() {
            ledger.workspaces[workspace.key] = .init(stage: .done, nextWorkspace: "next-\(index)")
        }
        for (key, skip) in plan.skipped where skip == .cloudVM { ledger.workspaces[key] = .init(stage: .skipped, reason: "cloud-vm") }
        return ledger
    }

    // MARK: Reading classic's session

    @Test func windowsGroupsColorsAndPinsAreRead() throws {
        let snapshot = try snapshot()
        #expect(snapshot.windows.count == 2)
        let first = snapshot.windows[0]
        #expect(first.workspaces.map(\.key) == [Self.home, Self.split, Self.pinned])
        #expect(first.selectedWorkspace == 1)
        #expect(first.groups == [
            ClassicSessionGroup(id: Self.backend, name: "Backend", collapsed: true, color: "#4ECDC4", icon: "server.rack"),
            ClassicSessionGroup(id: Self.saved, name: "Saved", pinned: true),
        ])
        let split = first.workspaces[1]
        #expect(split.groupID == Self.backend && split.color == "#FF6B6B" && !split.pinned)
        #expect(first.workspaces[2].pinned && first.workspaces[2].groupID == Self.backend)
        #expect(snapshot.windows[1].frame == CGRect(x: 420, y: 260, width: 1100, height: 700))
        #expect(snapshot.windows[1].workspaces[1].cloudVM == "vm-1")
    }

    /// Names stay unique across windows, as the import named them before.
    @Test func namesAreUniqueAcrossWindows() throws {
        let names = try snapshot().workspaces.map(\.name)
        #expect(Set(names).count == names.count, "\(names)")
    }

    /// A snapshot without `stableId` keys on `workspaceId`; one with neither
    /// on a digest that is the same on every read.
    @Test func keysFallBackToWorkspaceIDThenADigest() throws {
        func strip(_ fields: [String]) -> (inout [String: Any]) -> Void {
            { root in
                var windows = root["windows"] as? [[String: Any]] ?? []
                var manager = windows[0]["tabManager"] as? [String: Any] ?? [:]
                manager["workspaces"] = (manager["workspaces"] as? [[String: Any]] ?? []).map { workspace in
                    var workspace = workspace
                    for field in fields { workspace[field] = nil }
                    return workspace
                }
                windows[0]["tabManager"] = manager
                root["windows"] = windows
            }
        }
        let byWorkspaceID = try snapshot(strip(["stableId"])).windows[0].workspaces.map(\.key)
        #expect(byWorkspaceID.first == "BBBBBBBB-0000-4000-8000-000000000001")
        let derived = try snapshot(strip(["stableId", "workspaceId"])).windows[0].workspaces.map(\.key)
        #expect(derived.allSatisfy { $0.hasPrefix("derived:") } && Set(derived).count == 3, "\(derived)")
        #expect(try snapshot(strip(["stableId", "workspaceId"])).windows[0].workspaces.map(\.key) == derived)
    }

    /// A damaged file (JSON that is not a session object) is an error, never an empty session.
    @Test func aFileThatIsNotASessionIsAnError() {
        #expect(throws: ClassicSessionImportError.notASnapshot) {
            try ClassicSessionImporter(fileURL: Self.fixture).decodeSnapshot(Data("[1,2]".utf8))
        }
    }

    // MARK: The first run

    @Test func theFirstRunBringsEveryWindowInOrderWithItsGroups() throws {
        let plan = ClassicMigrationPlanner().plan(try snapshot(), ledger: nil, live: [], liveGroups: [], mode: .automatic)
        #expect(plan.windows.map { $0.workspaces.map(\.key) } == [[Self.home, Self.split, Self.pinned], [Self.second]])
        #expect(plan.windows[0].selectedKey == Self.split)
        // Window 2 had "second window" selected (index 2), which comes over.
        #expect(plan.windows[1].selectedKey == Self.second)
        #expect(plan.windows[1].frame == CGRect(x: 420, y: 260, width: 1100, height: 700))
        #expect(plan.groups.map(\.classic.id) == [Self.backend, Self.saved])
        #expect(plan.groups.allSatisfy { $0.existing == nil })
        #expect(plan.skipped == [Self.split: .duplicate, Self.cloud: .cloudVM])
        #expect(plan.cleanup.isEmpty)
    }

    // MARK: Already migrated

    @Test func aFinishedRunMakesNothingAgain() throws {
        let snapshot = try snapshot()
        let first = ClassicMigrationPlanner().plan(snapshot, ledger: nil, live: [], liveGroups: [], mode: .automatic)
        let ledger = finished(first, groups: [Self.backend: "grp_1", Self.saved: "grp_2"])
        let again = ClassicMigrationPlanner().plan(snapshot, ledger: ledger, live: ["next-0", "next-1", "next-2", "next-3"],
                                                   liveGroups: ["grp_1", "grp_2"], mode: .automatic)
        #expect(again.isEmpty, "\(again)")
        // Even when the person closed them all here, an automatic run brings none back.
        let closed = ClassicMigrationPlanner().plan(snapshot, ledger: ledger, live: [], liveGroups: [], mode: .automatic)
        #expect(closed.workspaces.isEmpty && closed.groups.isEmpty, "\(closed)")
    }

    /// Import Workspaces from Classic cmux brings back only what was closed here.
    @Test func aManualRunReopensOnlyWhatWasClosedHere() throws {
        let snapshot = try snapshot()
        let ledger = finished(ClassicMigrationPlanner().plan(snapshot, ledger: nil, live: [], liveGroups: [], mode: .automatic),
                              groups: [Self.backend: "grp_1", Self.saved: "grp_2"])
        let plan = ClassicMigrationPlanner().plan(snapshot, ledger: ledger, live: ["next-0", "next-2", "next-3"],
                                                  liveGroups: ["grp_1"], mode: .manual)
        #expect(plan.workspaces.map(\.key) == [Self.split])
        #expect(plan.groups == [ClassicMigrationPlan.Group(classic: snapshot.windows[0].groups[0], existing: "grp_1")])
        #expect(plan.skipped[Self.home] == .alreadyMigrated && plan.skipped[Self.cloud] == .cloudVM)
    }

    // MARK: Downgrade, then upgrade again

    /// Classic made a workspace in the Backend group while downgraded: only
    /// it comes over, into the group the first run made; changes classic made
    /// to workspaces that already came over are not merged (cmux-next's copy wins).
    @Test func aReUpgradeMergesOnlyNewWorkspacesIntoTheSameGroup() throws {
        let first = try snapshot()
        let ledger = finished(ClassicMigrationPlanner().plan(first, ledger: nil, live: [], liveGroups: [], mode: .automatic),
                              groups: [Self.backend: "grp_1", Self.saved: "grp_2"])
        let later = try snapshot { root in
            root["createdAt"] = 1_891_728_605.0
            var windows = root["windows"] as? [[String: Any]] ?? []
            var manager = windows[0]["tabManager"] as? [String: Any] ?? [:]
            var workspaces = manager["workspaces"] as? [[String: Any]] ?? []
            var added = workspaces[0]
            added["stableId"] = "AAAAAAAA-0000-4000-8000-000000000099"
            added["customTitle"] = "made while downgraded"
            added["groupId"] = Self.backend
            workspaces[1]["customTitle"] = "renamed in classic"
            workspaces.append(added)
            manager["workspaces"] = workspaces
            windows[0]["tabManager"] = manager
            root["windows"] = windows
        }
        #expect(ClassicMigrationPlanner().decision(.ledger(ledger), source: source(createdAt: 2), classicRunning: false) == .merge)
        let plan = ClassicMigrationPlanner().plan(later, ledger: ledger, live: ["next-0", "next-1", "next-2", "next-3"],
                                                  liveGroups: ["grp_1", "grp_2"], mode: .automatic)
        #expect(plan.workspaces.map(\.key) == ["AAAAAAAA-0000-4000-8000-000000000099"])
        #expect(plan.groups.map(\.existing) == ["grp_1"])
        // The pinned empty group came over once already; it is not made again.
        #expect(!plan.groups.contains { $0.classic.id == Self.saved })
    }

    /// The person deleted the group here: a merged member gets a new group, not a dangling id.
    @Test func aGroupDeletedHereIsMadeAgainForNewMembers() throws {
        let snapshot = try snapshot()
        var ledger = ClassicMigrationLedger(state: .completed, source: source(createdAt: 1), groups: [Self.backend: "grp_gone"])
        ledger.workspaces[Self.home] = .init(stage: .done, nextWorkspace: "next-0")
        let plan = ClassicMigrationPlanner().plan(snapshot, ledger: ledger, live: ["next-0"], liveGroups: [], mode: .automatic)
        #expect(plan.groups.first { $0.classic.id == Self.backend }?.existing == nil)
    }

    // MARK: A run cut off midway

    /// The app quit while a workspace was half made: it is closed and made
    /// again; one not yet started is made; finished ones are left alone.
    @Test func aCutOffRunResumesWithoutDuplicates() throws {
        let snapshot = try snapshot()
        var ledger = ClassicMigrationLedger(state: .inProgress, source: source(createdAt: 1))
        ledger.workspaces[Self.home] = .init(stage: .done, nextWorkspace: "next-0")
        ledger.workspaces[Self.split] = .init(stage: .created, nextWorkspace: "next-half")
        ledger.workspaces[Self.pinned] = .init(stage: .pending)
        #expect(ClassicMigrationPlanner().decision(.ledger(ledger), source: source(createdAt: 1), classicRunning: true) == .resume)
        let plan = ClassicMigrationPlanner().plan(snapshot, ledger: ledger, live: ["next-0", "next-half"], liveGroups: [],
                                                  mode: .automatic)
        #expect(plan.cleanup == ["next-half"])
        #expect(plan.workspaces.map(\.key) == [Self.split, Self.pinned, Self.second])
        #expect(plan.skipped[Self.home] == .alreadyMigrated)
    }

    // MARK: Whether a launch runs

    @Test(arguments: [
        (ClassicMigrationLedgerLoad.none, true, false, ClassicMigrationPlanner.Decision.firstRun),
        (.none, false, false, .skip(.noClassicSession)),
        (.none, true, true, .skip(.classicRunning)),
        (.newer(schema: 99), true, false, .skip(.ledgerNotUsable)),
        (.unreadable, true, false, .skip(.ledgerNotUsable)),
    ])
    func whetherALaunchRuns(_ load: ClassicMigrationLedgerLoad, _ hasSource: Bool, _ running: Bool,
                            _ expected: ClassicMigrationPlanner.Decision) {
        let decision = ClassicMigrationPlanner().decision(load, source: hasSource ? source(createdAt: 1) : nil, classicRunning: running)
        #expect(decision == expected)
    }

    @Test func theSameClassicSaveRunsOnce() {
        let ledger = ClassicMigrationLedger(state: .completed, source: source(createdAt: 1))
        let planner = ClassicMigrationPlanner()
        #expect(planner.decision(.ledger(ledger), source: source(createdAt: 1), classicRunning: false) == .skip(.unchanged))
        // The `-previous` copy of the same save is the same save.
        let previous = ClassicMigrationSource(path: "/s/session-com.cmuxterm.app-previous.json", bundleID: "com.cmuxterm.app",
                                              size: 99, modifiedAt: 5, createdAt: 1)
        #expect(planner.decision(.ledger(ledger), source: previous, classicRunning: false) == .skip(.unchanged))
        // Classic saved again while still running: wait until it quits.
        #expect(planner.decision(.ledger(ledger), source: source(createdAt: 2), classicRunning: true) == .skip(.classicRunning))
    }

    // MARK: cmux-next in use before its first migration

    /// The tree already had workspaces (cmux-next in use, classic work maybe
    /// moved by hand): classic's workspaces are only recorded. No automatic
    /// run makes them; the action still can.
    @Test func aBaselineRecordsWithoutMaking() throws {
        let snapshot = try snapshot()
        let ledger = ClassicMigrationPlanner().baseline(snapshot, ledger: ClassicMigrationLedger())
        #expect(ledger.state == .completed)
        #expect(ClassicMigrationPlanner().plan(snapshot, ledger: ledger, live: [], liveGroups: [], mode: .automatic).workspaces.isEmpty)
        let manual = ClassicMigrationPlanner().plan(snapshot, ledger: ledger, live: [], liveGroups: [], mode: .manual)
        #expect(manual.workspaces.map(\.key) == [Self.home, Self.split, Self.pinned, Self.second])
    }
}

/// The migration's folder and how it finds classic's files: never writing classic's.
@Suite struct ClassicMigrationRepositoryTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-migration-\(UUID().uuidString.prefix(8))")

    private func write(_ text: String, _ path: String, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    @Test func aLedgerRoundTrips() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ClassicMigrationRepository(directory: root.appendingPathComponent("m"))
        #expect(await repository.load() == .none)
        var ledger = ClassicMigrationLedger(state: .completed, groups: ["g": "grp_1"], runs: 2)
        ledger.workspaces["k"] = .init(stage: .done, nextWorkspace: "w")
        try await repository.save(ledger)
        #expect(await repository.load() == .ledger(ledger))
    }

    /// A newer cmux-next's ledger is left as it is; this build only stops.
    @Test func aNewerLedgerIsLeftAlone() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(#"{"schema":7,"future":true}"#, "m/ledger.json")
        let repository = ClassicMigrationRepository(directory: root.appendingPathComponent("m"))
        #expect(await repository.load() == .newer(schema: 7))
        #expect(try String(contentsOf: file, encoding: .utf8) == #"{"schema":7,"future":true}"#)
    }

    @Test func aDamagedLedgerIsMovedAside() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("{not json", "m/ledger.json")
        let repository = ClassicMigrationRepository(directory: root.appendingPathComponent("m"))
        #expect(await repository.load() == .unreadable)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("m").path)
        #expect(!names.contains("ledger.json") && names.contains { $0.hasPrefix("ledger.unreadable-") }, "\(names)")
    }

    /// Backups copy classic's files; the originals keep their bytes and dates.
    @Test func backupsCopyAndNeverTouchClassicFiles() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let session = try write("{\"windows\":[]}", "support/cmux/session-com.cmuxterm.app.json", modified: date)
        let repository = ClassicMigrationRepository(directory: root.appendingPathComponent("m"))
        for index in 0..<7 {
            let folder = try #require(try await repository.backup([session, root.appendingPathComponent("missing.json")], stamp: "2026101\(index)"))
            #expect(try Data(contentsOf: folder.appendingPathComponent(session.lastPathComponent)) == Data("{\"windows\":[]}".utf8))
        }
        #expect(try Data(contentsOf: session) == Data("{\"windows\":[]}".utf8))
        let modified = try FileManager.default.attributesOfItem(atPath: session.path)[.modificationDate] as? Date
        #expect(modified == date)
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("m/backups").path).sorted()
        #expect(kept == (2..<7).map { "2026101\($0)" })
    }

    /// cmux-next nightly reads classic nightly's session; stable reads stable's.
    @Test func theOwnChannelIsPreferredThenTheNewest() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("{}", "support/cmux/session-com.cmuxterm.app.json", modified: Date(timeIntervalSince1970: 1))
        _ = try write("{}", "support/cmux/session-com.cmuxterm.app.nightly.json", modified: Date(timeIntervalSince1970: 2))
        _ = try write("{}", "support/cmux/session-com.cmuxterm.app.debug.json", modified: Date(timeIntervalSince1970: 9))
        let support = root.appendingPathComponent("support")
        #expect(ClassicMigrationSourceFinder(support: support, ownBundleID: "com.cmuxterm.app").channel() == "com.cmuxterm.app")
        #expect(ClassicMigrationSourceFinder(support: support, ownBundleID: "com.cmuxterm.app.nightly.cmux-next").channel()
                == "com.cmuxterm.app.nightly")
        // A channel classic never saved falls back to the newest one; debug is never a source.
        #expect(ClassicMigrationSourceFinder(support: support, ownBundleID: "com.cmuxterm.app.rc").channel() == "com.cmuxterm.app.nightly")
    }

    /// The session file, its `-previous` copy, then the newest archive of the same channel only.
    @Test func candidatesAreTheFileItsCopyThenTheNewestArchive() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = try write("{}", "support/cmux/session-com.cmuxterm.app.json")
        let previous = try write("{}", "support/cmux/session-com.cmuxterm.app-previous.json")
        _ = try write("{}", "support/cmux/session-history/session-com.cmuxterm.app-1000-w1-p1.json")
        let newest = try write("{}", "support/cmux/session-history/session-com.cmuxterm.app-2000-w1-p1.json")
        _ = try write("{}", "support/cmux/session-history/session-com.cmuxterm.app.nightly-9000-w1-p1.json")
        let finder = ClassicMigrationSourceFinder(support: root.appendingPathComponent("support"), ownBundleID: "com.cmuxterm.app")
        #expect(finder.candidates().map(\.url.lastPathComponent) == [primary, previous, newest].map(\.lastPathComponent))
    }
}

import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// LAUNCH 800 (2026-11-10): a relaunch with the person's session (826 workspaces) must show the focused workspace,
/// ready for a key, as fast as a relaunch with 60. So the launch path must do no work per HIDDEN workspace on the main
/// thread: the shown workspace first, the rest lazily (CLAUDE.md "Copy Chrome's performance model": Chromium's
/// `SessionRestore` shows the selected tab at once and only schedules every other tab; "Go past Chrome": a hidden
/// workspace updates the model only).
///
/// Each test runs the app's launch in a whole window (`AppServices`, every observer the app starts), in the order of
/// `AppDelegate`: the daemon's launch snapshot applies as a provisional tree with its saved window record
/// (`DaemonService.showLaunchSnapshot`), `WindowManager.restoreWhenLoaded` opens the launch window on the saved
/// workspace, then the daemon's first live snapshot (the same tree) applies. Two phases are counted:
///
/// - `snapshot`: from the provisional apply to the launch window with its workspace content laid out.
/// - `live`: the first live snapshot's apply and what it wakes, until the main actor is idle.
///
/// Counted: the sidebar's work (`SidebarView.perfCounters`: rows mapped, rows laid out, row views made), the workspace
/// snapshots the store walks on the main actor (`snapshotWorkspacesWalkedOnMain`, `workspaceListWalkedOnMain`) and the
/// observation trackings the live apply wakes (`ObservationWakes`, by the `#fileID:#line` of each woken observer; one
/// wake is one registration made again). Not counted here: the saved windows' restore (`WindowManager.restore` needs
/// the daemon's window records), the terminal attach and the kept terminals' restarts; a launch on a bench host
/// measures those.
///
/// Sizes: `large` (60) always, and each other size `CMUX_TEST_SESSION_SIZES` names (826 runs on a mini, never by
/// default: `SessionFixtureSize`). No count of a larger size may be larger than the count at `large`: a count that
/// grows with the session is work per hidden workspace. (A count may be smaller at the larger size: at 826 the live
/// apply woke `PaneController.swift:46` 2 times against 6 at 60, so an equality check gave a false red.)
///
///     CMUX_TEST_SESSION_SIZES=large,real swift test --filter LaunchSessionCountTests
@MainActor @Suite(.serialized) struct LaunchSessionCountTests {
    typealias Fixture = LargeSessionWindowFixture

    static let sizes: [SessionFixtureSize] = [.large] + SessionFixtureSize.arms.filter { $0 != .large }

    /// What one phase of the launch did on the main actor.
    struct Phase: Sendable {
        var wakes: [String: Int] = [:]
        var sidebar: [String: Int] = [:]
        /// Workspace snapshots the store compared or keyed on the main actor.
        var snapshotsWalked = 0
        /// Confirmed workspace records an apply walked to rebuild the list.
        var listWalked = 0

        var wakeTotal: Int { wakes.values.reduce(0, +) }
    }

    struct Counts: Sendable {
        var snapshot = Phase()
        var live = Phase()
    }

    /// One measured launch per size, for the whole suite: a window of 826 workspaces takes seconds to open.
    private static var measured: [SessionFixtureSize: Counts] = [:]

    /// The sidebar counters a launch must keep flat, and what each one is.
    static let sidebarRows = ["row_maps", "layout_rows", "row_views_made", "row_configures", "row_frames", "row_invalidations",
                              "section_sets", "rebuilds", "list_reloads", "order_builds"]

    /// The launch of a session of `size`, counted.
    static func counts(_ size: SessionFixtureSize) async throws -> Counts {
        if let counts = measured[size] { return counts }
        try #require(size.mixFaults.isEmpty, "fixture: the \(size.rawValue) mix is wrong: \(size.mixFaults)")
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let daemon = services.daemon
        let store = daemon.store
        let tree = Fixture.tree(size)
        var counts = Counts()

        // Phase `snapshot`, as `DaemonService.showLaunchSnapshot` then `AppDelegate`: the provisional tree, the saved
        // window (it shows the last workspace and holds every workspace), the launch window.
        _ = SidebarView.perfCounters(reset: true)
        var walked = (store.snapshotWorkspacesWalkedOnMain, store.workspaceListWalkedOnMain)
        store.applyProvisional(snapshot: tree)
        let keys = (1...size.workspaces).map { WorkspaceKey(rawValue: Fixture.key($0)) }
        let record = WindowRecord(id: "launch-800-window", workspaceKey: keys.last, workspaceKeys: keys,
                                  frame: WindowFrame(x: 200, y: 200, width: 1600, height: 900))
        daemon.launchSnapshotWindows = WindowStateDocument(windows: [record])
        services.windows.restoreWhenLoaded()
        defer {
            for controller in services.windows.controllers {
                controller.teardown()
                controller.window?.close()
            }
        }
        let controller = try #require(services.windows.controllers.first, "fixture: the launch snapshot opened no window")
        for _ in 0..<50 where controller.workspaceContent == nil { await Fixture.drainMain() }
        let content = try #require(controller.workspaceContent, "fixture: the launch window shows no workspace content")
        try #require(controller.state.workspaceID == Fixture.key(size.workspaces), "fixture: the launch window shows \(controller.state.workspaceID ?? "nothing")")
        content.contentView.layoutSubtreeIfNeeded()
        await Fixture.drainMain()
        try #require(store.isProvisional && store.workspaces.count == size.workspaces, "fixture: the launch snapshot is not the store's tree")
        counts.snapshot.sidebar = SidebarView.perfCounters(reset: true)
        counts.snapshot.snapshotsWalked = store.snapshotWorkspacesWalkedOnMain - walked.0
        counts.snapshot.listWalked = store.workspaceListWalkedOnMain - walked.1

        // Phase `live`: the handshake, then the daemon's first snapshot: the tree the launch snapshot showed.
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        walked = (store.snapshotWorkspacesWalkedOnMain, store.workspaceListWalkedOnMain)
        let wakes = ObservationWakes()
        ObservationWakes.$current.withValue(wakes) {
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: tree)
        }
        await Fixture.drainMain()
        content.contentView.layoutSubtreeIfNeeded()
        await Fixture.drainMain()
        try #require(!store.isProvisional && store.isLoaded && store.workspaces.count == size.workspaces, "fixture: the live snapshot did not load")
        counts.live.wakes = wakes.bySite
        counts.live.sidebar = SidebarView.perfCounters(reset: true)
        counts.live.snapshotsWalked = store.snapshotWorkspacesWalkedOnMain - walked.0
        counts.live.listWalked = store.workspaceListWalkedOnMain - walked.1

        measured[size] = counts
        // Every count, also when the test passes: what a launch does on the main actor, at each size.
        for (name, phase) in [("snapshot", counts.snapshot), ("live", counts.live)] {
            for site in phase.wakes.keys.sorted() { print("LaunchSessionCount \(size.rawValue) \(name) wakes \(site): \(phase.wakes[site] ?? 0)") }
            print("LaunchSessionCount \(size.rawValue) \(name) wakes total: \(phase.wakeTotal); snapshots_walked \(phase.snapshotsWalked), "
                + "list_walked \(phase.listWalked); sidebar: " + sidebarRows.map { "\($0) \(phase.sidebar[$0] ?? 0)" }.joined(separator: ", "))
        }
        return counts
    }

    /// `value` of each size run; the test fails when a larger size has a larger value than `large`.
    private static func expectFlat(_ what: String, value: (Counts) -> Int) async throws {
        var all: [SessionFixtureSize: Counts] = [:]
        for size in sizes { all[size] = try await counts(size) }
        let values = sizes.map { "\($0.rawValue) \(value(all[$0] ?? Counts()))" }
        let small = value(all[.large] ?? Counts())
        #expect(sizes.allSatisfy { value(all[$0] ?? Counts()) <= small }, "\(what) grows with the session: \(values)")
    }

    /// The sites the live apply woke more often at a larger size than at `large`, largest growth first.
    private static func grew(_ all: [SessionFixtureSize: Counts]) -> [String] {
        guard let small = all[.large]?.live.wakes else { return [] }
        return all.filter { $0.key != .large }.flatMap { size, counts in
            counts.live.wakes.filter { $0.value > small[$0.key, default: 0] }.sorted { $0.value > $1.value }.prefix(12)
                .map { "\($0.key) \(small[$0.key, default: 0]) -> \($0.value) at \(size.rawValue)" }
        }
    }

    /// The launch window's sidebar maps the rows it can show, not one row per workspace of the session.
    @Test(.timeLimit(.minutes(10)))
    func theLaunchWindowMapsAsManySidebarRowsInALargerSession() async throws {
        try await Self.expectFlat("sidebar rows mapped for the launch window") { $0.snapshot.sidebar["row_maps", default: 0] }
    }

    /// The launch window's sidebar lays out the rows it can show.
    @Test(.timeLimit(.minutes(10)))
    func theLaunchWindowLaysOutAsManySidebarRowsInALargerSession() async throws {
        try await Self.expectFlat("sidebar rows laid out for the launch window") { $0.snapshot.sidebar["layout_rows", default: 0] }
    }

    /// The launch window makes the row views it shows (the control: this count is flat already).
    @Test(.timeLimit(.minutes(10)))
    func theLaunchWindowMakesAsManySidebarRowViewsInALargerSession() async throws {
        try await Self.expectFlat("sidebar row views made for the launch window") { $0.snapshot.sidebar["row_views_made", default: 0] }
    }

    /// The first live snapshot equals the tree the launch snapshot showed: the store walks no workspace for it.
    @Test(.timeLimit(.minutes(10)))
    func theFirstLiveSnapshotWalksAsManyWorkspacesInALargerSession() async throws {
        try await Self.expectFlat("workspaces the first live snapshot walks on the main actor") {
            $0.live.snapshotsWalked + $0.live.listWalked
        }
    }

    /// The first live snapshot wakes the observers of the shown workspace and of the session's state, never one per
    /// workspace.
    @Test(.timeLimit(.minutes(10)))
    func theFirstLiveSnapshotWakesAsManyObserversInALargerSession() async throws {
        var all: [SessionFixtureSize: Counts] = [:]
        for size in Self.sizes { all[size] = try await Self.counts(size) }
        let grew = Self.grew(all)
        #expect(grew.isEmpty, "observers the first live snapshot wakes more often in a larger session: \(grew)")
    }

    /// The first live snapshot maps again only the sidebar rows it changes.
    @Test(.timeLimit(.minutes(10)))
    func theFirstLiveSnapshotMapsAsManySidebarRowsInALargerSession() async throws {
        try await Self.expectFlat("sidebar rows the first live snapshot maps") { $0.live.sidebar["row_maps", default: 0] }
    }
}

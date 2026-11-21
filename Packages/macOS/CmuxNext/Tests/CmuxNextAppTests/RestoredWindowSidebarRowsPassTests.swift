import AppKit
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextLayout
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// A window runs its sidebar's rows pass one time, in the pass's task: a window that the launch's restore opens,
/// and a new window.
///
/// The restore makes each saved window and then writes `registry.isLaunching = false`, in one turn. The rows pass
/// reads that value. A rows pass that runs while the window is made (in front of its order-in) reads `true` and its
/// registration is on that value: the write of `false` marks the pass, and the pass's task runs it a second time,
/// which is a second walk of each row and a second fill of the rows feed for each restored window. The window
/// manager's `present` runs no pass, for any window (2026-11-16): each pass's first run is its task's, one hop
/// after the order-in. The spaces of the space bar do not wait for that run: the sidebar's seed writes them from
/// the store (`NewWindowSidebarRowsFirstFrameTests`).
///
/// The count is the process counter `rebuilds` (`SidebarView.perfCounters`): one for each fill of a sidebar's rows
/// feed, and the rows pass is the one caller of that fill. Each test sets the counter to zero in its own body, after
/// the app is made and before the window is made. No other window adds to it: the suite has a process of its own in
/// CI (it is in `OWN_PROCESS` of `scripts/cmux-next/main-thread-heavy-suites.py`; in a process that suites share, a
/// sidebar that another suite left open can run its rows pass in the hops and add to the count), this suite is
/// serialized, and each test makes one window and closes it.
///
/// Each window here has no workspace: the content swap of a window with a workspace can run the rows pass by its own
/// rule, and these tests do not count that run. No test waits for time to pass; `hops` says what the drain reaches.
@MainActor @Suite(.serialized, .closesItsWindows) struct RestoredWindowSidebarRowsPassTests {
    /// The hops that `drain` gives the main actor: 8.
    ///
    /// A second run needs one hop. Each pass's task is queued when the sidebar is made, in front of the test's first
    /// yield, and the pass's stream holds one wake from the registration: the task's first job takes that wake and,
    /// if a write marked the pass, runs it. A stream that hands a held wake over in a new job makes that two hops.
    /// A run that marks its own pass again adds at most one hop for each such run. Eight hops are four times the
    /// two, with room for six runs more.
    ///
    /// The number is checked by a run, not only by this count: two tests here read the counter at 0 in front of
    /// the drain and at 1 after it, and that run is the first job of the pass's task.
    static let hops = 8

    /// Lets the main actor run what is queued, `hops` times.
    static func drain() async {
        for _ in 0..<hops { await Task.yield() }
    }

    /// The runs of a rows pass in this process since the counter was set to zero.
    static var rowsPassRuns: Int { SidebarView.perfCounters(reset: false)["rebuilds"] ?? 0 }

    /// The trackings of the sidebar's bridge that a write woke, by the place that made each one.
    static func bridgeWakes(_ wakes: ObservationWakes) -> [String: Int] {
        wakes.bySite.filter { $0.key.hasPrefix("CmuxNextApp/SidebarBridge.swift:") }
    }

    /// The restore's turn: a saved window is made and presented, then the launch ends, with no suspension between.
    @Test func aWindowThatTheLaunchRestoresRunsItsRowsPassOneTime() async throws {
        let services = try NewWindowSidebarRowsFirstFrameTests.app()
        let windows = services.windows, id = "restored-rows-pass"
        windows.previousLaunch = PreviousLaunch(windowIDs: [id], restoredAtMs: 0)
        windows.registry.isLaunching = true
        try #require(windows.restoresSession(id), "the fixture is wrong: the window is not one that the launch restores")
        _ = SidebarView.perfCounters(reset: true)
        let controller = windows.makeController(for: WindowRegistry.Window(id: id))
        defer {
            controller.teardown()
            controller.window?.close()
            withExtendedLifetime(services) {} // the window does not keep the app
        }
        let wakes = ObservationWakes()
        ObservationWakes.$current.withValue(wakes) { windows.registry.isLaunching = false }
        // Read in the turn of the write, with no hop: a pass that the write woke is run a second time by its task.
        let woken = Self.bridgeWakes(wakes)
        #expect(woken.isEmpty, "the end of the launch woke a pass that ran while the window was made: \(woken)")
        await Self.drain()
        let runs = Self.rowsPassRuns
        #expect(runs == 1, "the rows pass of a window that the launch restores ran \(runs) times")
    }

    /// What `present` leaves to the passes' tasks for a window that the launch restores, and what the window has
    /// at its order-in. The window here has no saved sidebar. At its order-in no rows pass ran, and the model has
    /// the spaces: the seed wrote them from the store. The band items have their values: that check runs for each
    /// window. After the launch's end the pass's task runs the pass one time and the spaces are the same.
    @Test func aWindowThatTheLaunchRestoresKeepsItsPassesForTheirTasks() async throws {
        let services = try NewWindowSidebarRowsFirstFrameTests.app()
        let windows = services.windows, id = "restored-no-saved-sidebar"
        try #require(services.sidebarSnapshots.launchDocument.snapshot(for: id, fallback: true) == nil, "the fixture is wrong: the window has a saved sidebar")
        windows.previousLaunch = PreviousLaunch(windowIDs: [id], restoredAtMs: 0)
        windows.registry.isLaunching = true
        try #require(windows.restoresSession(id), "the fixture is wrong: the window is not one that the launch restores")
        _ = SidebarView.perfCounters(reset: true)
        let controller = windows.makeController(for: WindowRegistry.Window(id: id))
        defer {
            controller.teardown()
            controller.window?.close()
            withExtendedLifetime(services) {} // the window does not keep the app
        }
        let model = controller.sidebar.model
        try #require(model.layout.item(NewWindowSidebarFirstFrameTests.home.id) != nil, "the fixture is wrong: the window's band does not list the item that the fixture set")
        // The values are emptied after the window is made, so only this call of `present` can write them again.
        model.itemInfo = [:]
        windows.present(controller)
        #expect(SidebarFirstFrame(model).isComplete, "present left band items of a restored window with no info: \(SidebarFirstFrame(model).faults.map(\.id.rawValue))")
        let atOrderIn = Self.rowsPassRuns
        #expect(atOrderIn == 0, "the rows pass of a window that the launch restores ran \(atOrderIn) times in front of the order-in")
        #expect(model.profiles.map(\.id.rawValue) == NewWindowSidebarRowsFirstFrameTests.spaces, "a restored window with no saved sidebar is ordered in with no spaces in the model: the seed did not write the store's")
        windows.registry.isLaunching = false
        await Self.drain()
        #expect(model.profiles.map(\.id.rawValue) == NewWindowSidebarRowsFirstFrameTests.spaces, "the pass's task wrote other spaces of a restored window after the launch's end")
        let runs = Self.rowsPassRuns
        #expect(runs == 1, "the rows pass of a window that the launch restores ran \(runs) times")
    }

    /// The spaces that the seed takes from the store are not a saved sidebar's. The rows pass keeps a saved
    /// sidebar's spaces while the launch's store lists none; it must not keep these, or a space that the store
    /// dropped would stay in the bar. The window here has no saved sidebar and the store lists two spaces at the
    /// seed. Then the store lists none, in the launch: a run of the rows pass writes the store's list, which is empty.
    @Test func theSeedsSpacesFromTheStoreAreNotKeptAsASavedSidebarsAre() throws {
        let services = try NewWindowSidebarRowsFirstFrameTests.app()
        let windows = services.windows, id = "restored-seed-spaces"
        try #require(services.sidebarSnapshots.launchDocument.snapshot(for: id, fallback: true) == nil, "the fixture is wrong: the window has a saved sidebar")
        windows.previousLaunch = PreviousLaunch(windowIDs: [id], restoredAtMs: 0)
        windows.registry.isLaunching = true
        try #require(windows.restoresSession(id), "the fixture is wrong: the window is not one that the launch restores")
        let controller = windows.makeController(for: WindowRegistry.Window(id: id))
        defer {
            controller.teardown()
            controller.window?.close()
            withExtendedLifetime(services) {} // the window does not keep the app
        }
        let model = controller.sidebar.model
        try #require(model.profiles.map(\.id.rawValue) == NewWindowSidebarRowsFirstFrameTests.spaces, "the fixture is wrong: the seed wrote no spaces from the store")
        services.machines.local.store.profiles = []
        let launching = SidebarBridge.passSections(services, window: controller.state).1
        try #require(launching, "the fixture is wrong: the rows pass does not read a launch, so it keeps no spaces at all")
        controller.sidebar.sameTurn.syncNow(rows: true)
        #expect(model.profiles.isEmpty, "the rows pass kept the spaces that the seed took from the store, as it keeps a saved sidebar's")
    }

    /// The control: a window that is not the launch's. No rows pass runs in the turn that makes the window, and
    /// the pass's task runs it one time.
    @Test func aNewWindowRunsItsRowsPassOneTime() async throws {
        let services = try NewWindowSidebarRowsFirstFrameTests.app()
        let windows = services.windows, id = "new-rows-pass"
        try #require(!windows.registry.isLaunching && !windows.restoresSession(id), "the fixture is wrong: the app is in its launch")
        _ = SidebarView.perfCounters(reset: true)
        let controller = windows.makeController(for: WindowRegistry.Window(id: id))
        defer {
            controller.teardown()
            controller.window?.close()
            withExtendedLifetime(services) {} // the window does not keep the app
        }
        let made = Self.rowsPassRuns
        #expect(made == 0, "the rows pass of a new window ran \(made) times in the turn that made the window")
        await Self.drain()
        let runs = Self.rowsPassRuns
        #expect(runs == 1, "the rows pass of a new window ran \(runs) times")
    }
}

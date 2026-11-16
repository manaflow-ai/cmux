import AppKit
@testable import CmuxNextApp
import CmuxNextAppCore
import CmuxNextCompat
import CmuxNextLayout
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// A window that the launch's restore opens runs its sidebar's rows pass one time.
///
/// The restore makes each saved window and then writes `registry.isLaunching = false`, in one turn. The rows pass
/// reads that value. A rows pass that runs while the window is made (in front of its order-in) reads `true` and its
/// registration is on that value: the write of `false` marks the pass, and the pass's task runs it a second time,
/// which is a second walk of each row and a second fill of the rows feed for each restored window. So the window
/// manager's `present` runs no pass for such a window (2026-11-16): its passes run in their tasks only. A
/// window that is not the launch's reads `false` while it is made and no write follows: its pass runs one time,
/// in front of its order-in.
///
/// The count is the process counter `rebuilds` (`SidebarView.perfCounters`): one for each fill of a sidebar's rows
/// feed, and the rows pass is the one caller of that fill. Each test sets the counter to zero in its own body, after
/// the app is made and before the window is made. No other window adds to it: the suite runner starts one process for
/// each suite, this suite is serialized, and each test makes one window and closes it.
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
    /// The number is checked by a run, not only by this count: in `SidebarSameTurnPendingTests`, a change after the
    /// call is run by the pass's task inside one drain, and that run is the same first job of the task.
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

    /// What `present` leaves to the passes' tasks for a window that the launch restores, and what it keeps. The
    /// window here has no saved sidebar. At its order-in no rows pass ran and the sidebar has no first-frame sample,
    /// so the model has no spaces: the limit of the rule, the space bar comes one hop after the first frame, as
    /// before the passes ran in front of an order-in. The band items have their values: that check runs for each
    /// window. After the launch's end the pass's task writes the spaces, in one run.
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
        #expect(controller.sidebar.sameTurn.firstFrame == nil, "a window that the launch restores has a first-frame sample: a pass ran in front of its order-in")
        #expect(model.profiles.isEmpty, "a restored window with no saved sidebar has its spaces at the order-in: the limit that the texts name is gone")
        windows.registry.isLaunching = false
        await Self.drain()
        #expect(model.profiles.map(\.id.rawValue) == NewWindowSidebarRowsFirstFrameTests.spaces, "the pass's task did not write the spaces of a restored window after the launch's end")
        let runs = Self.rowsPassRuns
        #expect(runs == 1, "the rows pass of a window that the launch restores ran \(runs) times")
    }

    /// The control: a window that is not the launch's. Its rows pass runs in the turn that makes the window, and
    /// the pass's task runs it no second time.
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
        #expect(made == 1, "the rows pass of a new window ran \(made) times in the turn that made the window")
        await Self.drain()
        let runs = Self.rowsPassRuns
        #expect(runs == 1, "the rows pass of a new window ran \(runs) times")
    }
}

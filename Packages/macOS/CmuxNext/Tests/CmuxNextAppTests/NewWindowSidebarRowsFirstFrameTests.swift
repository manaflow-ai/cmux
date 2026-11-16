import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextLayout
@testable import CmuxNextSidebar
import Foundation
import Testing

/// At its order-in a new window's sidebar has the spaces of the space bar and the window's own space. The sidebar's
/// bridge shows the window's rows in the turn that makes it (its seed), and registers the rows pass, whose first run
/// is a task's: it starts a hop later. The window manager's `present` orders the window in at the end of the turn
/// that makes it. The space bar hides while the model has fewer than two spaces, and the list gets the bar's room:
/// when only the rows pass wrote the spaces, a window of a session with two spaces was ordered in with no bar, and
/// the bar came in a hop later. The seed writes the spaces and the window's space now, from the store, by the
/// function that the rows pass uses (2026-11-16), and no rows pass runs in front of the order-in. The rows'
/// decorations and the page faces are the rows pass's still: they come one hop after the order-in, as before, and
/// no test here reads them.
///
/// Each test makes a window as the window manager makes it and reads the model after `present` with no suspension,
/// so no task has run (two tests say where they let the tasks run). The window is never ordered in
/// (`ordersWindowsIn`) and no test draws a frame. The session and the band are those of
/// `NewWindowSidebarFirstFrameTests`, with two spaces.
@MainActor @Suite(.serialized) struct NewWindowSidebarRowsFirstFrameTests {
    static let work = ProfileID(rawValue: "prof_work")
    static let spaces = [ProfileID.defaultProfile.rawValue, work.rawValue]

    /// The app over a session with one open workspace and two spaces. It orders no window in.
    static func app() throws -> AppServices {
        let services = try NewWindowSidebarFirstFrameTests.app()
        services.machines.local.store.profiles = [ProfileModel(ProfileSnapshot(id: .defaultProfile, name: "Home")),
                                                  ProfileModel(ProfileSnapshot(id: work, name: "Work", index: 1))]
        services.windows.ordersWindowsIn = false
        return services
    }

    /// The sidebar's work counters (`SidebarPerfCounters`) that the work in front of a window's order-in moves: the
    /// rows passes with the rows feed (`rebuilds`), the full reloads of the list, the row views made. A count has no
    /// clock and no Mac in it.
    struct Work {
        let rebuilds: Int, listReloads: Int, rowViewsMade: Int

        /// The counters as they are now. They are the process's: a test reads them twice with no suspension between.
        static var now: Work {
            Work(rebuilds: SidebarPerfCounters.count(.rebuilds), listReloads: SidebarPerfCounters.count(.listReloads),
                 rowViewsMade: SidebarPerfCounters.count(.rowViewsMade))
        }

        /// What was added after `start`.
        func since(_ start: Work) -> Work {
            Work(rebuilds: rebuilds - start.rebuilds, listReloads: listReloads - start.listReloads, rowViewsMade: rowViewsMade - start.rowViewsMade)
        }

        var text: String { "rebuilds=\(rebuilds) list_reloads=\(listReloads) row_views_made=\(rowViewsMade)" }
    }

    /// One window with the app that owns it: the window does not keep the app, so the test does.
    @MainActor struct Made {
        let services: AppServices
        let controller: WindowController
        /// The counters in front of the window manager's call that made and presented the window.
        let start: Work
        /// The sidebar work of that call.
        let work: Work
        var model: SidebarModel { controller.sidebar.model }

        func close() {
            controller.teardown()
            controller.window?.close()
        }
    }

    /// The window `id` of that app, made and presented by the window manager. `listsTheWorkspace` gives the window
    /// the session's open workspace and takes the pins out of the band, so the list has the workspace's row.
    /// `creating` is the key of a create in flight into the window: its row is in `PendingWorkspaceRows` under the
    /// window's id in front of the window's making, as a new window with a new workspace has it from the press. The
    /// caller takes the row out again (`PendingWorkspaceRows.remove`): the rows are the process's.
    static func window(_ id: String, listsTheWorkspace: Bool = false, creating: String? = nil) throws -> Made {
        let services = try app()
        if listsTheWorkspace {
            services.sidebarLayout.docLayout = NewWindowSidebarFirstFrameTests.document(pins: [])
            services.windows.registry.provisional[id] = ["k-open"]
        }
        let listed = SidebarSpaceBar.profiles(services.machines.local, window: id, windows: services.windows)
        try #require(listed.map(\.id.rawValue) == spaces, "the fixture is wrong: the rows pass would not list the two spaces")
        if let creating {
            PendingWorkspaceRows.shared.add(creating: creating, window: id, machine: CmuxNextSidebar.MachineID(services.machines.local.machineID), name: "created",
                                            opensPage: true, slot: nil, byDefault: nil)
        }
        let start = Work.now
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: id)) // it presents a window with no workspace of its own at once
        return Made(services: services, controller: controller, start: start, work: Work.now.since(start))
    }

    /// A window with no workspace yet.
    @Test func presentHasTheSpacesBeforeTheOrderIn() throws {
        let made = try Self.window("rows-first-frame-empty")
        defer { made.close() }
        let model = made.model
        #expect(model.profiles.map(\.id.rawValue) == Self.spaces, "the window is ordered in with no spaces in the model: the bar is hidden in its first frame")
        #expect(model.activeProfileID?.rawValue == made.controller.state.profileID.rawValue)
    }

    /// A window that has the session's open workspace in its list.
    @Test func presentOfAWindowWithAWorkspaceHasTheSpacesBeforeTheOrderIn() throws {
        let made = try Self.window("rows-first-frame-listed", listsTheWorkspace: true)
        defer { made.close() }
        let model = made.model
        #expect(model.profiles.map(\.id.rawValue) == Self.spaces, "the window is ordered in with no spaces in the model: the bar is hidden in its first frame")
        #expect(model.activeProfileID?.rawValue == made.controller.state.profileID.rawValue)
        #expect(!model.sections.flatMap(\.workspaces).isEmpty, "the fixture is wrong: the window lists no workspace")
    }

    /// At the order-in the model has the spaces and the window's space as the rows pass writes them: a run of the
    /// pass after `present`, in the same turn, changes neither. The pass's other values (the rows with their
    /// decorations and page faces) are not read here: the seed does not write them as the pass does.
    @Test func theRowsPassWritesTheSameSpacesAfterPresent() throws {
        let made = try Self.window("rows-first-frame-same", listsTheWorkspace: true)
        defer { made.close() }
        let model = made.model
        let bar = model.profiles, space = model.activeProfileID
        made.controller.sidebar.sameTurn.syncNow(rows: true)
        #expect(model.profiles == bar, "the rows pass wrote other spaces after the order-in")
        #expect(model.activeProfileID == space, "the rows pass wrote another space of the window after the order-in")
    }

    /// The work in front of the order-in, as a count (decision of 2026-11-16: the measure of that work is a count,
    /// not a time). The window manager's call that makes and presents a window runs no rows pass: a rows pass reads
    /// each workspace of the window's space. The list reloads in full two times in that call: one time when the
    /// list is made, one time at the window's first draw (its space page). The count is exact: this fixture owns
    /// each value that the call reads, and a third reload is a second draw of each row in front of the order-in.
    /// The row views made in that call are in the printed line `NEW-WINDOW-WORK` and in the message; they have no
    /// bound here.
    @Test func theMakingOfAWindowRunsNoRowsPass() throws {
        let made = try Self.window("rows-first-frame-work", listsTheWorkspace: true)
        defer { made.close() }
        print("NEW-WINDOW-WORK \(made.work.text)")
        #expect(made.work.rebuilds == 0, "the making of the window ran a rows pass in front of its order-in (\(made.work.text))")
        #expect(made.work.listReloads == 2, "the making of the window did not reload the list two times in front of its order-in (\(made.work.text))")
    }

    /// The work from the start of the making to the end of the rows pass's first run, printed as the line
    /// `NEW-WINDOW-WORK-AFTER-THE-PASS`: the test lets the tasks run (`RestoredWindowSidebarRowsPassTests.drain`)
    /// and then draws the sidebar in its own turn, so the line's `list_reloads` is each full reload of the list that
    /// the window's making, its rows pass and that draw made. The one assert says that the pass ran in the hops:
    /// without it the line says nothing. The counts have no bound here.
    @Test func theWorkToTheEndOfTheRowsPassIsPrinted() async throws {
        let made = try Self.window("rows-first-frame-after", listsTheWorkspace: true)
        defer { made.close() }
        await RestoredWindowSidebarRowsPassTests.drain()
        made.controller.sidebar.sameTurn.syncNow(rows: false) // no rows pass: it draws what the model has
        let work = Work.now.since(made.start)
        print("NEW-WINDOW-WORK-AFTER-THE-PASS \(work.text)")
        #expect(work.rebuilds >= 1, "the rows pass of the window did not run in the hops (\(work.text))")
    }

    /// A create in flight into a new window, with the pointer over the window's rows. The seed lists the window's
    /// rows without the create's row (it passes no rows of creates), and the rows pass's first run lists it: a
    /// change of the rows that comes after the window's first draw. A change of the rows that nobody in this window
    /// asked for waits while the pointer is over the rows (`SidebarListView.showModelChange`). The first set of a
    /// new window's rows pass is part of the window's making, so it must show at once: before the seed wrote the
    /// window's space, that run was the window's space change, which reloads with no condition. The pointer's answer
    /// is the list's seam (`pointerIsOverList`), set after the making; the assert reads the list's own state: no
    /// clock, no poll and no real pointer.
    @Test func theFirstRowsPassOfANewWindowShowsACreatesRowUnderThePointer() async throws {
        let created = "rows-first-frame-created"
        let made = try Self.window("rows-first-frame-pointer", listsTheWorkspace: true, creating: created)
        defer {
            made.close()
            PendingWorkspaceRows.shared.remove(created)
        }
        let model = made.model, list = made.controller.sidebar.container.sidebarView.list
        let lists = { model.sections.flatMap(\.workspaces).contains { $0.id.rawValue == created } }
        try #require(!list.displayed.rows.isEmpty, "the fixture is wrong: the window's first draw lists no row")
        try #require(!lists(), "the fixture is wrong: the seed listed the create's row, so the rows pass adds no row")
        list.pointerIsOverList = { _ in true }
        await RestoredWindowSidebarRowsPassTests.drain()
        made.controller.sidebar.sameTurn.syncNow(rows: false) // no rows pass: it draws what the model has
        try #require(lists(), "the fixture is wrong: the rows pass did not list the create's row in the hops")
        #expect(!list.holdsModelChange, "the first rows pass of a new window left its rows to wait for the pointer to leave the list")
        #expect(list.displayed.row(for: .workspace(CmuxNextSidebar.WorkspaceID(created))) != nil,
                "a new window's list does not draw the create's row while the pointer is over its rows")
    }

    /// The show at once is the first run's only (decision of 2026-11-16). This window has no create at its making,
    /// so the first run of its rows pass changes no row; that run uses the show at once up. Then a create's row
    /// comes and the rows pass runs again: a change of the rows that nobody in this window asked for, with the
    /// pointer over the rows, so the list keeps it back (`SidebarListView.showModelChange`). The pointer's answer is
    /// the list's seam; the asserts read the list's own state: no clock, no poll and no real pointer.
    @Test func aLaterSetOfANewWindowsRowsPassWaitsUnderThePointer() async throws {
        let id = "rows-first-frame-later-set", created = "rows-first-frame-created-later"
        let made = try Self.window(id, listsTheWorkspace: true)
        defer {
            made.close()
            PendingWorkspaceRows.shared.remove(created)
        }
        let model = made.model, list = made.controller.sidebar.container.sidebarView.list
        let lists = { model.sections.flatMap(\.workspaces).contains { $0.id.rawValue == created } }
        try #require(!list.displayed.rows.isEmpty, "the fixture is wrong: the window's first draw lists no row")
        list.pointerIsOverList = { _ in true }
        await RestoredWindowSidebarRowsPassTests.drain() // the first run of the rows pass
        made.controller.sidebar.sameTurn.syncNow(rows: false) // no rows pass: it draws what the model has
        try #require(Work.now.since(made.start).rebuilds >= 1, "the fixture is wrong: the rows pass of the window did not run in the hops")
        try #require(!list.holdsModelChange, "the fixture is wrong: the list holds a change after the first run of the rows pass")
        PendingWorkspaceRows.shared.add(creating: created, window: id, machine: CmuxNextSidebar.MachineID(made.services.machines.local.machineID), name: "created",
                                        opensPage: true, slot: nil, byDefault: nil)
        made.controller.sidebar.sameTurn.syncNow(rows: true) // the rows pass again, then the draw
        try #require(lists(), "the fixture is wrong: the second run of the rows pass did not list the create's row")
        #expect(list.holdsModelChange, "a later set of a new window's rows pass did not wait while the pointer is over the rows")
        #expect(list.displayed.row(for: .workspace(CmuxNextSidebar.WorkspaceID(created))) == nil,
                "a later set of a new window's rows pass drew its row under the pointer")
    }

    /// The debug measure of a new workspace's row (`SidebarNewRowTimer`, the socket method `debug.new_workspace`)
    /// ends at the draw that lists the row. A new window's first draw is the list's space page (the seed wrote the
    /// window's space), and that draw ends the measure's waiting entry, as the list's reload did when the first
    /// draw had no space. The assert reads the measure's own state: no clock and no poll.
    @Test func theFirstDrawOfANewWindowEndsTheNewRowMeasure() throws {
        let listed = try Self.window("rows-first-frame-row-id", listsTheWorkspace: true)
        let first = listed.model.sections.flatMap(\.workspaces).first?.id.rawValue
        listed.close()
        let row = try #require(first, "the fixture is wrong: the window lists no workspace")
        let measure = SidebarNewRowTimer.shared
        measure.timer.start()
        defer { measure.timer.stop() }
        measure.began(row)
        try #require(measure.timer.isWaiting(row), "the fixture is wrong: the measure does not wait for the row")
        let made = try Self.window("rows-first-frame-measure", listsTheWorkspace: true)
        defer { made.close() }
        try #require(made.model.sections.flatMap(\.workspaces).contains(where: { $0.id.rawValue == row }), "the fixture is wrong: the window does not list the row")
        made.controller.sidebar.sameTurn.syncNow(rows: false) // no rows pass: the sidebar's first draw, if the window's making did not draw it
        #expect(!measure.timer.isWaiting(row), "a new window's first draw listed the row and left the measure's entry open")
    }
}

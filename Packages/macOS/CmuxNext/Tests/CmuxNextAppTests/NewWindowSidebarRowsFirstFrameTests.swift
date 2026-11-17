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
    /// `hidesTheBandsWorkspaces` is that of `NewWindowSidebarFirstFrameTests.app`.
    static func app(hidesTheBandsWorkspaces: Bool = false) throws -> AppServices {
        let services = try NewWindowSidebarFirstFrameTests.app(hidesTheBandsWorkspaces: hidesTheBandsWorkspaces)
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
        /// The changes of the selection that the list drew on its rows with no reload.
        let selectionPatches: Int

        /// The counters as they are now. They are the process's: a test reads them twice with no suspension between.
        static var now: Work {
            Work(rebuilds: SidebarPerfCounters.count(.rebuilds), listReloads: SidebarPerfCounters.count(.listReloads),
                 rowViewsMade: SidebarPerfCounters.count(.rowViewsMade), selectionPatches: SidebarPerfCounters.count(.selectionPatches))
        }

        /// What was added after `start`.
        func since(_ start: Work) -> Work {
            Work(rebuilds: rebuilds - start.rebuilds, listReloads: listReloads - start.listReloads, rowViewsMade: rowViewsMade - start.rowViewsMade,
                 selectionPatches: selectionPatches - start.selectionPatches)
        }

        var text: String { "rebuilds=\(rebuilds) list_reloads=\(listReloads) row_views_made=\(rowViewsMade)" }

        /// `text` with the list's draws of a selection.
        var textWithTheSelection: String { "\(text) selection_patches=\(selectionPatches)" }
    }

    /// The state of the workspace that a new window shows at its making. The type's name is from a read that a run
    /// of 2026-11-17 showed wrong for the first case: the seed lists that workspace.
    enum Unlisted: String {
        /// The band pins the workspace (the band of `NewWindowSidebarFirstFrameTests` as it is): the workspace draws
        /// as an item of the band. By that run the seed of the window lists the workspace's row too. By a read, not
        /// by a run, why: this fixture's layout service has no daemon behind it, and the list then takes no
        /// workspace of the band out (the older projection, `SidebarTopProjection.legacy`).
        case pinnedInTheBand = "pinned_in_the_band"
        /// The band pins the workspace, and the list's projection is the layout's (`app(hidesTheBandsWorkspaces:)`):
        /// the workspace is an item of the band and has no row in the list. By a read, not by a run, this is the
        /// state of a pinned workspace in the app with the daemon's layout.
        case hiddenByTheBand = "hidden_by_the_band"
        /// The workspace is pinned to the space `work`, and no item of the band names it. A new window starts at the
        /// space `default`: the window manager enters the workspace's space after the window's making.
        case ofAnotherSpace = "of_another_space"
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
    /// caller takes the row out again (`PendingWorkspaceRows.remove`): the rows are the process's. `unlisted` gives
    /// the window the session's open workspace in one of the states of `Unlisted`.
    static func window(_ id: String, listsTheWorkspace: Bool = false, creating: String? = nil, unlisted: Unlisted? = nil) throws -> Made {
        let services = try app(hidesTheBandsWorkspaces: unlisted == .hiddenByTheBand)
        if listsTheWorkspace {
            services.sidebarLayout.docLayout = NewWindowSidebarFirstFrameTests.document(pins: [])
            services.windows.registry.provisional[id] = ["k-open"]
        }
        if let unlisted {
            services.windows.registry.provisional[id] = ["k-open"]
            if unlisted == .ofAnotherSpace {
                services.sidebarLayout.docLayout = NewWindowSidebarFirstFrameTests.document(pins: [])
                // The session's personal state with one pin, written as the fixture writes the two spaces: no daemon sends it.
                let personal = services.machines.local.store.personal
                personal.isLoaded = true
                personal.pins = [WorkspacePin(sessionID: NewWindowSidebarFirstFrameTests.session, workspaceKey: WorkspaceKey(rawValue: "k-open"), profile: work)]
            }
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

    /// A new window for a workspace that exists (a workspace moved to a window of its own). The content swap of the
    /// window's making (`WindowController.show`) runs the rows pass in the making's turn when the model does not
    /// list the workspace or lists another space than the window's. That run is then the first run of the window's
    /// rows pass, the run that shows at once, and it is not a task's; the swap then runs the selection pass and
    /// draws the sidebar. The swap must add no draw of the list (decision of 2026-11-16): the call that makes the
    /// window reloads the list in full the two times of each window's making (`theMakingOfAWindowRunsNoRowsPass`)
    /// and draws no selection on the list's rows after the reloads (`selection_patches`). A third reload, or a
    /// selection patch, is a draw of the list for the selection after the run's show drew it without the selection.
    /// `rowsPasses` is the count of rows passes that the swap runs in the case, as a run of 2026-11-17 showed it
    /// (one run of the suite, on one Mac): the first assert says with it which path the printed line is of. The
    /// work is in the printed line `NEW-WINDOW-WORK-IN-THE-SWAP` with the case's name. A draw of the band's own
    /// items has no counter and is not read here.
    static func expectTheSwapAddsNoDrawOfTheList(_ made: Made, _ unlisted: Unlisted, rowsPasses: Int) throws {
        let work = made.work
        print("NEW-WINDOW-WORK-IN-THE-SWAP \(unlisted.rawValue) \(work.textWithTheSelection)")
        try #require(work.rebuilds == rowsPasses,
                     "the fixture is wrong: the content swap of the window's making did not run \(rowsPasses) rows passes (\(work.textWithTheSelection))")
        #expect(work.listReloads == 2, "the content swap of a new window's making did not reload the list two times (\(work.textWithTheSelection))")
        #expect(work.selectionPatches == 0, "the content swap of a new window's making drew the list again for the selection (\(work.textWithTheSelection))")
    }

    /// The workspace is an item of the band, and the swap's selection is that item. By the run of 2026-11-17 the
    /// swap runs NO rows pass here: the seed listed the workspace's row, so the swap draws what the model has, and
    /// the counts are those of a window's plain making. The two checks in front say that state of the fixture. By
    /// a read, not by a run: with the daemon's layout a workspace of the band leaves the list, and the swap of its
    /// new window then runs the rows pass and selects the band's item. The next test makes that window with the
    /// test's own layout service.
    @Test func theSwapOfANewWindowForAWorkspaceOfTheBandAddsNoDrawOfTheList() throws {
        let made = try Self.window("rows-first-frame-swap-band", unlisted: .pinnedInTheBand)
        defer { made.close() }
        try #require(!made.model.sections.flatMap(\.workspaces).isEmpty, "the fixture is wrong: the seed listed no row, so the swap runs the rows pass")
        try #require(made.model.selectedItem == SidebarItem.topItem(NewWindowSidebarFirstFrameTests.open.id),
                     "the fixture is wrong: the swap did not select the band's item of the workspace")
        try Self.expectTheSwapAddsNoDrawOfTheList(made, .pinnedInTheBand, rowsPasses: 0)
    }

    /// The workspace is an item of the band and the list has no row for it (the layout's projection, from the
    /// test's own layout service: no daemon). By a run of 2026-11-17 (one run of the suite, on one Mac): the swap
    /// then runs ONE rows pass, the first run of the window's rows pass, and after it the selection pass selects
    /// the band's item. That run, made before this test had its two asserts of a count, printed `list_reloads=2
    /// selection_patches=1` for this swap: one selection patch, a draw of the list for the selection after the
    /// first run's show drew it without the selection. The swap must add no draw of the list in this case too
    /// (decision of 2026-11-17): the three checks in front say that the window is in that state, that the swap ran
    /// the rows pass one time and that the selection is the band's item; the line `NEW-WINDOW-WORK-IN-THE-SWAP
    /// hidden_by_the_band` has the counts of that swap.
    @Test func theSwapOfANewWindowForAWorkspaceThatTheBandHidesAddsNoDrawOfTheList() throws {
        let made = try Self.window("rows-first-frame-swap-hidden", unlisted: .hiddenByTheBand)
        defer { made.close() }
        let selectsTheBandsItem = made.model.selectedItem == SidebarItem.topItem(NewWindowSidebarFirstFrameTests.open.id)
        print("NEW-WINDOW-WORK-IN-THE-SWAP \(Unlisted.hiddenByTheBand.rawValue) \(made.work.textWithTheSelection) selects_the_bands_item=\(selectsTheBandsItem)")
        try #require(made.model.sections.flatMap(\.workspaces).isEmpty, "the fixture is wrong: the list keeps the row of the band's workspace")
        try #require(made.work.rebuilds == 1, "the fixture is wrong: the content swap of the window's making did not run one rows pass (\(made.work.textWithTheSelection))")
        try #require(selectsTheBandsItem, "the fixture is wrong: the swap did not select the band's item of the workspace")
        #expect(made.work.listReloads == 2, "the content swap of a new window's making did not reload the list two times (\(made.work.textWithTheSelection))")
        #expect(made.work.selectionPatches == 0, "the content swap of a new window's making drew the list again for the selection (\(made.work.textWithTheSelection))")
    }

    /// The workspace is in another space than the window's first one. By the run of 2026-11-17 the swap runs ONE
    /// rows pass, the first run of the window's rows pass: it lists the rows of the space `default`, as the seed
    /// did, and the selection has no row and no item of the band.
    @Test func theSwapOfANewWindowForAWorkspaceOfAnotherSpaceAddsNoDrawOfTheList() throws {
        let made = try Self.window("rows-first-frame-swap-space", unlisted: .ofAnotherSpace)
        defer { made.close() }
        try #require(made.model.sections.flatMap(\.workspaces).isEmpty, "the fixture is wrong: the space `default` lists the workspace that is pinned to another space")
        try Self.expectTheSwapAddsNoDrawOfTheList(made, .ofAnotherSpace, rowsPasses: 1)
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

    /// The same create and the same pointer, with the first run of the rows pass inside a draw of the turn
    /// (`syncNow(rows: true)`, the call of a window's content swap) and not in a task. A guard that was not red
    /// first: by a read the run shows its rows at once there too (`SidebarView.showRowsOfTheMaking`, called by the
    /// run itself), so the list draws the create's row under the pointer and holds no change back. The test calls
    /// `syncNow` itself: no row here makes a window whose content swap runs that first run with a create in flight.
    @Test func theFirstRowsPassInsideADrawOfTheTurnShowsACreatesRowUnderThePointer() throws {
        let created = "rows-first-frame-created-in-turn"
        let made = try Self.window("rows-first-frame-pointer-in-turn", listsTheWorkspace: true, creating: created)
        defer {
            made.close()
            PendingWorkspaceRows.shared.remove(created)
        }
        let model = made.model, list = made.controller.sidebar.container.sidebarView.list
        let lists = { model.sections.flatMap(\.workspaces).contains { $0.id.rawValue == created } }
        try #require(!list.displayed.rows.isEmpty, "the fixture is wrong: the window's first draw lists no row")
        try #require(!lists(), "the fixture is wrong: the seed listed the create's row, so the rows pass adds no row")
        try #require(made.work.rebuilds == 0, "the fixture is wrong: a rows pass ran in the window's making, so the next run is not the first")
        list.pointerIsOverList = { _ in true }
        made.controller.sidebar.sameTurn.syncNow(rows: true) // the first run of the rows pass, the selection pass, the draw
        try #require(lists(), "the fixture is wrong: the rows pass did not list the create's row")
        #expect(!list.holdsModelChange, "the first rows pass of a new window, run with a draw of its turn, left its rows to wait for the pointer to leave the list")
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

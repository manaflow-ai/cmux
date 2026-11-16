import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
import CmuxNextLayout
@testable import CmuxNextSidebar
import Foundation
import Testing

/// At its order-in a new window's sidebar has what its rows pass writes: the spaces of the space bar, the window's
/// own space, and the rows. The sidebar's bridge shows the window's rows in the turn that makes it, and registers
/// the rows pass, whose first run is a task's: it starts a hop later. The window manager's `present` orders the
/// window in at the end of the turn that makes it, so what only the rows pass writes is not in the model for that
/// hop. The space bar hides while the model has fewer than two spaces, and the list gets the bar's room: a window
/// of a session with two spaces is ordered in with no bar, and the bar comes in a hop later.
///
/// Each test makes a window as the window manager makes it and reads the model after `present` with no suspension,
/// so no task has run. The window is never ordered in (`ordersWindowsIn`) and no test draws a frame. The session
/// and the band are those of `NewWindowSidebarFirstFrameTests`, with two spaces.
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
        /// The sidebar work of the window manager's call that made and presented the window.
        let work: Work
        var model: SidebarModel { controller.sidebar.model }

        func close() {
            controller.teardown()
            controller.window?.close()
        }
    }

    /// The window `id` of that app, made and presented by the window manager. `listsTheWorkspace` gives the window
    /// the session's open workspace and takes the pins out of the band, so the list has the workspace's row.
    static func window(_ id: String, listsTheWorkspace: Bool = false) throws -> Made {
        let services = try app()
        if listsTheWorkspace {
            services.sidebarLayout.docLayout = NewWindowSidebarFirstFrameTests.document(pins: [])
            services.windows.registry.provisional[id] = ["k-open"]
        }
        let listed = SidebarSpaceBar.profiles(services.machines.local, window: id, windows: services.windows)
        try #require(listed.map(\.id.rawValue) == spaces, "the fixture is wrong: the rows pass would not list the two spaces")
        let start = Work.now
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: id)) // it presents a window with no workspace of its own at once
        return Made(services: services, controller: controller, work: Work.now.since(start))
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

    /// At the order-in the model has each value that the rows pass writes: a run of the pass after `present`, in
    /// the same turn, changes none of them.
    @Test func theRowsPassChangesNothingAfterPresent() throws {
        let made = try Self.window("rows-first-frame-same", listsTheWorkspace: true)
        defer { made.close() }
        let model = made.model
        let bar = model.profiles, space = model.activeProfileID
        let sections = model.sections, folded = model.collapsedSections, projection = model.sectionCustomization
        made.controller.sidebar.sameTurn.syncNow(rows: true)
        #expect(model.profiles == bar, "the rows pass wrote the spaces after the order-in")
        #expect(model.activeProfileID == space, "the rows pass wrote the window's space after the order-in")
        #expect(model.sections == sections, "the rows pass changed the rows after the order-in")
        #expect(model.collapsedSections == folded)
        #expect(model.sectionCustomization == projection)
    }

    /// The work in front of the order-in, as a count (decision of 2026-11-16: the measure of that work is a count,
    /// not a time). The window manager's call that makes and presents a window runs no rows pass: a rows pass reads
    /// each workspace of the window's space, and the list reloads in full after it. The list's full reloads and the
    /// row views made in that call are in the printed line `NEW-WINDOW-WORK` and in the message; they have no bound
    /// here.
    @Test func theMakingOfAWindowRunsNoRowsPass() throws {
        let made = try Self.window("rows-first-frame-work", listsTheWorkspace: true)
        defer { made.close() }
        print("NEW-WINDOW-WORK \(made.work.text)")
        #expect(made.work.rebuilds == 0, "the making of the window ran a rows pass in front of its order-in (\(made.work.text))")
    }
}

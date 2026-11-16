import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDaemon
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

    /// One window with the app that owns it: the window does not keep the app, so the test does.
    @MainActor struct Made {
        let services: AppServices
        let controller: WindowController
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
        let controller = services.windows.makeController(for: WindowRegistry.Window(id: id))
        services.windows.present(controller)
        return Made(services: services, controller: controller)
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
}

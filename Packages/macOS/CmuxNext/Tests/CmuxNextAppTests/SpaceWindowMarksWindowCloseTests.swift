import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// #38333 review: closing a window that something still retains does not take its content view out of the window, so
/// the switcher bar never hears `viewDidMoveToWindow` and its marks kept observing every window. The window's teardown
/// (`WindowController.teardown`, through `SidebarBridge.teardown`) stops them, for good.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SpaceWindowMarksWindowCloseTests {
    @Test func closingARetainedWindowStopsItsSwitcherMarks() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try PlacementStaleRowsTests.identity(mixedOrder: false)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: PlacementStaleRowsTests.tree(["only"], personal: ["only"]))
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["only"]))
        let window = try #require(controller.window)
        let marks = controller.sidebar.container.sidebarView.spaceWindowMarks
        try #require(marks.isObserving, "an open window's switcher observes the windows")

        window.close()

        #expect(controller.sidebar.container.sidebarView.window === window, "the retained window kept its views")
        #expect(!marks.isObserving, "the closed window's switcher still observes every window")
        // A later move into a window (a reused view) does not start it again.
        marks.isActive = false
        marks.isActive = true
        #expect(!marks.isObserving, "the torn-down marks observed again")
        #expect(marks.perform == nil, "the torn-down marks still run switcher choices")
    }
}

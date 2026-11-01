import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextTestSupport
import Foundation
import Testing

/// The sidebar footer's Search button opens the same centered palette as Cmd-P, not a small
/// popup above the button (Lawrence, 2026-10-25): `palette.open {scope: search}` centers the panel
/// over the window whether or not the window shows the button.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarSearchOpensCenteredTests {
    @Test func pressingSearchCentersThePanelOverTheWindow() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let controller = try #require(services.windows.openWindow(workspaces: ["search-ws"], frame: CGRect(x: 200, y: 200, width: 1200, height: 760)))
        let window = try #require(controller.window)
        var palettePanel: NSWindow?
        defer {
            services.palette.hide()
            // `hide()` fades the panel out and orders it out, kept for the next open: close it.
            palettePanel?.close()
            controller.teardown()
            window.close()
        }
        window.orderFront(nil)
        // The footer button's own handler, the path a click takes.
        let sidebar = controller.sidebar.container.sidebarView
        sidebar.onSearch?(sidebar)
        let panel = try #require(services.palette.visiblePanel, "pressing Search opened no palette")
        palettePanel = panel
        #expect(abs(panel.frame.midX - window.frame.midX) <= 1, "panel \(panel.frame) is not centered over \(window.frame)")
        #expect(panel.frame.maxY > window.frame.maxY - window.frame.height / 3, "panel \(panel.frame) does not reach the upper third of \(window.frame)")
    }
}

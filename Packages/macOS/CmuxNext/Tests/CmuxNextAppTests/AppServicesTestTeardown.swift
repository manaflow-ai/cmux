import AppKit
@testable import CmuxNextApp
import CmuxNextPalette
import CmuxNextTestSupport

extension AppServices {
    /// A test harness's teardown for the app it ran: closes its windows and the panels the app
    /// keeps between opens. A browser page's Page Info and Extensions panels and the palette's
    /// panel are only ordered out when they hide; the app closes them when a page retires or it
    /// quits, which a harness never does (`.closesItsWindows`).
    func closeWindowsForTest() {
        for controller in windows.controllers { controller.window?.close() }
        for entry in cache.browsers.values { entry.close() }
        palette.hide()
        for panel in NSApp.windows where palette.owns(panel) { panel.closeAfterTest() }
    }
}

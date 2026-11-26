import Foundation
import Testing
@testable import CmuxNextBrowser

/// Views window mode (a prototype, `InTreePages.isViewsWindow`): Chromium starts with the fork's switch, and with
/// AsyncLiveResize off so its window bridge holds the window's commit for the page frames at a new window size (its
/// async path needs NativeWidgetMacNSWindow's own frame interception, which an adopted cmux window lacks).
@Suite struct CEFViewsWindowSwitchTests {
    @Test func offByDefault() {
        let switches = CEFSwitches.current(forkAPIVersion: 36, bundleIdentifier: "com.cmuxterm.app.debug.tag", environment: [:])
        #expect(!switches.arguments.contains(CEFSwitches.viewsWindowSwitch))
        #expect(!switches.arguments.contains("disable-features=AsyncLiveResize"))
    }

    @Test func onItAddsTheSwitchAndTurnsAsyncLiveResizeOff() {
        var switches = CEFSwitches.current(forkAPIVersion: 36, bundleIdentifier: "com.cmuxterm.app.debug.tag", environment: [:])
        switches.viewsWindow = true
        #expect(switches.arguments.contains("cmux-views-window"))
        #expect(switches.arguments.contains("disable-features=AsyncLiveResize"))
    }

    @Test func theAsyncLiveResizeKnobKeepsChromiumsDefault() {
        var switches = CEFSwitches.current(forkAPIVersion: 36, bundleIdentifier: "com.cmuxterm.app.debug.tag",
                                           environment: ["CMUX_NEXT_VIEWS_WINDOW_ASYNC_LIVE_RESIZE": "1"])
        switches.viewsWindow = true
        #expect(switches.arguments.contains("cmux-views-window"))
        #expect(!switches.arguments.contains("disable-features=AsyncLiveResize"))
    }
}

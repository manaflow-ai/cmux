import XCTest

/// Stress finding F3 (scratch diagnostic, never lands): the list rig opens a workspace with 80 tabs
/// (`tabs-push`) and then its tab grid (`tabs-open-grid`) while `test ui=... profile` records a Time
/// Profiler trace, so the grid-open frame can be read from the trace on its own.
final class GridOpenProfileUITests: XCTestCase {
    @MainActor
    func testOpenGridWith80Tabs() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "tabs"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "80"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }
        // The rig: open delay, 1 s, the push (2 s), 1 s, then the grid (2 s). 20 s covers it twice over.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "rig")], timeout: 20)
        XCTAssertEqual(app.state, .runningForeground)
    }
}

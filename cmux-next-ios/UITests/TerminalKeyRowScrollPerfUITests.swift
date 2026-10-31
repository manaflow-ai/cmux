import XCTest

/// Profiles the terminal key row's horizontal scroll (the composer's shortcut
/// strip): flings it left and right on the demo terminal and records the
/// scroll's hitches and the app's CPU. Run before and after a key row change
/// and compare; the key row once re-evaluated every glass key on every scroll
/// frame.
final class TerminalKeyRowScrollPerfUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testKeyRowScrollPerformance() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
        app.launch()

        let escape = app.buttons["terminal.key.escape"]
        XCTAssertTrue(escape.waitForExistence(timeout: 20), "key row\n\(app.debugDescription)")
        let row = app.buttons["terminal.key.control"]

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)],
                options: options) {
            row.swipeLeft(velocity: .fast)
            row.swipeLeft(velocity: .fast)
            escape.swipeRight(velocity: .fast)
            escape.swipeRight(velocity: .fast)
        }
    }
}

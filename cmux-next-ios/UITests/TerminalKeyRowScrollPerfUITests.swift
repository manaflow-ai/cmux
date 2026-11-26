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

        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        let control = app.buttons["terminal.key.control"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), "key row\n\(app.debugDescription)")
        // These points stay inside the scroller even after its first keys scroll out of view.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let frame = app.frame
        let rowY = control.frame.midY - frame.minY
        let left = origin.withOffset(CGVector(dx: control.frame.midX - frame.minX, dy: rowY))
        let right = origin.withOffset(CGVector(dx: frame.width * 0.92, dy: rowY))

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)],
                options: options) {
            for _ in 0..<2 {
                right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .fast, thenHoldForDuration: 0)
            }
            for _ in 0..<2 {
                left.press(forDuration: 0.05, thenDragTo: right, withVelocity: .fast, thenHoldForDuration: 0)
            }
        }
    }
}

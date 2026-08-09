import XCTest

final class NativeScrollInteractionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testFastDragUsesContinuousNativeDeceleration() throws {
        let metrics = app.staticTexts["nativeScrollMetrics"]
        XCTAssertTrue(metrics.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        window.swipeDown(velocity: .fast)

        XCTAssertTrue(metrics.label.contains("IDLE"))
        let audit = try XCTUnwrap(metrics.value as? String)
        XCTAssertTrue(audit.contains("Deceleration observed"), audit)
        XCTAssertTrue(audit.contains("Fixed chrome stable"), audit)
        let rows = audit.matches(of: /row (\d+)/).compactMap { UInt64($0.1) }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], rows[1])
    }

    func testBottomEdgeOverscrollReturnsToRest() throws {
        let metrics = app.staticTexts["nativeScrollMetrics"]
        XCTAssertTrue(metrics.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(
            forDuration: 0.4,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 0.2
        )

        let settledMetrics = metrics.label
        XCTContext.runActivity(named: "Settled metrics: \(settledMetrics)") { _ in }
        let values = settledMetrics.matches(of: /-?\d+\.\d/).compactMap {
            Double($0.output)
        }
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values[0], values[1], accuracy: 0.2)
        XCTAssertEqual(values[2], 0, accuracy: 0.2)
    }
}

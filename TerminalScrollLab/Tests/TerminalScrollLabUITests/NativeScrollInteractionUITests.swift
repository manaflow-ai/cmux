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
        let initialMetrics = metrics.label

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
        start.press(
            forDuration: 0.05,
            thenDragTo: end,
            withVelocity: .fast,
            thenHoldForDuration: 0
        )

        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@", initialMetrics),
            object: metrics
        )
        wait(for: [changed], timeout: 3)
        XCTAssertTrue(metrics.label.contains("IDLE"))
    }

    func testBottomEdgeOverscrollReturnsToRest() throws {
        let metrics = app.staticTexts["nativeScrollMetrics"]
        XCTAssertTrue(metrics.waitForExistence(timeout: 5))
        let restingMetrics = metrics.label

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        start.press(
            forDuration: 0.4,
            thenDragTo: end,
            withVelocity: .slow,
            thenHoldForDuration: 0.2
        )

        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", restingMetrics),
            object: metrics
        )
        wait(for: [returned], timeout: 3)
    }
}

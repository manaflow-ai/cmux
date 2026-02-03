import XCTest

final class SidebarResizeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSidebarResizerTracksCursor() {
        let app = XCUIApplication()
        app.launch()
        app.activate()

        let elements = app.descendants(matching: .any)
        let resizer = elements["SidebarResizer"]
        XCTAssertTrue(resizer.waitForExistence(timeout: 5.0))
        createTabs(app: app, count: 8)

        let initialX = resizer.frame.minX

        let start = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 80, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end)

        let afterX = resizer.frame.minX
        XCTAssertEqual(afterX, initialX + 80, accuracy: 2.0)

        let startBack = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endBack = startBack.withOffset(CGVector(dx: -120, dy: 0))
        startBack.press(forDuration: 0.1, thenDragTo: endBack)

        let afterBackX = resizer.frame.minX
        XCTAssertEqual(afterBackX, afterX - 120, accuracy: 2.0)
    }

    func testSidebarResizerResponsiveTiming() {
        let app = XCUIApplication()
        app.launch()
        app.activate()

        let elements = app.descendants(matching: .any)
        let resizer = elements["SidebarResizer"]
        XCTAssertTrue(resizer.waitForExistence(timeout: 5.0))
        createTabs(app: app, count: 12)

        let iterations = 8
        let dragDistance: CGFloat = 80
        var totalSeconds = 0.0

        for i in 0..<iterations {
            let startSeconds = CFAbsoluteTimeGetCurrent()
            let start = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let deltaX = (i % 2 == 0) ? dragDistance : -dragDistance
            let end = start.withOffset(CGVector(dx: deltaX, dy: 0))
            start.press(forDuration: 0.1, thenDragTo: end)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            totalSeconds += CFAbsoluteTimeGetCurrent() - startSeconds
        }

        let averageSeconds = totalSeconds / Double(iterations)
        XCTContext.runActivity(named: "Sidebar resize timing") { activity in
            let attachment = XCTAttachment(
                string: String(
                    format: "avg=%.3fs total=%.3fs iterations=%d",
                    averageSeconds,
                    totalSeconds,
                    iterations
                )
            )
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        XCTAssertLessThan(averageSeconds, 0.9, "Sidebar resize too slow: avg=\(averageSeconds)s")
    }

    private func createTabs(app: XCUIApplication, count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            app.typeKey("t", modifierFlags: .command)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}

import XCTest

final class SidebarResizeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testSidebarResizerTracksCursor() {
        let app = makeApp()
        app.launch()
        app.activate()

        let elements = app.descendants(matching: .any)
        let resizer = elements["SidebarResizer"]
        XCTAssertTrue(resizer.waitForExistence(timeout: 5.0))
        createTabs(app: app, count: 8)

        let initialX = resizer.frame.minX

        let dragForward: CGFloat = 80
        let dragBackward: CGFloat = -120

        let scale = max(NSScreen.main?.backingScaleFactor ?? 1.0, 1.0)
        let expectedForward = dragForward / scale
        let expectedBackward = dragBackward / scale

        let start = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: dragForward, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let afterX = resizer.frame.minX
        XCTContext.runActivity(named: "Sidebar resize forward") { activity in
            let attachment = XCTAttachment(
                string: String(
                    format: "scale=%.2f initialX=%.1f afterX=%.1f delta=%.1f expected=%.1f",
                    scale,
                    initialX,
                    afterX,
                    afterX - initialX,
                    expectedForward
                )
            )
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        XCTAssertEqual(afterX - initialX, expectedForward, accuracy: 12.0)

        let startBack = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endBack = startBack.withOffset(CGVector(dx: dragBackward, dy: 0))
        startBack.press(forDuration: 0.1, thenDragTo: endBack)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let afterBackX = resizer.frame.minX
        XCTContext.runActivity(named: "Sidebar resize backward") { activity in
            let attachment = XCTAttachment(
                string: String(
                    format: "scale=%.2f afterX=%.1f afterBackX=%.1f delta=%.1f expected=%.1f",
                    scale,
                    afterX,
                    afterBackX,
                    afterBackX - afterX,
                    expectedBackward
                )
            )
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        XCTAssertEqual(afterBackX - afterX, expectedBackward, accuracy: 25.0)
    }

    func testSidebarResizerResponsiveTiming() {
        let app = makeApp()
        app.launch()
        app.activate()

        let elements = app.descendants(matching: .any)
        let resizer = elements["SidebarResizer"]
        XCTAssertTrue(resizer.waitForExistence(timeout: 5.0))
        createTabs(app: app, count: 12)

        let iterations = 8
        let warmupIterations = 1
        let dragDistance: CGFloat = 80
        var totalSeconds = 0.0
        var measuredIterations = 0

        for i in 0..<iterations {
            let startSeconds = CFAbsoluteTimeGetCurrent()
            let start = resizer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let deltaX = (i % 2 == 0) ? dragDistance : -dragDistance
            let end = start.withOffset(CGVector(dx: deltaX, dy: 0))
            start.press(forDuration: 0.1, thenDragTo: end)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if i >= warmupIterations {
                totalSeconds += CFAbsoluteTimeGetCurrent() - startSeconds
                measuredIterations += 1
            }
        }

        let averageSeconds = totalSeconds / Double(max(measuredIterations, 1))
        XCTContext.runActivity(named: "Sidebar resize timing") { activity in
            let attachment = XCTAttachment(
                string: String(
                    format: "avg=%.3fs total=%.3fs iterations=%d",
                    averageSeconds,
                    totalSeconds,
                    measuredIterations
                )
            )
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        XCTAssertLessThan(averageSeconds, 1.4, "Sidebar resize too slow: avg=\(averageSeconds)s")
    }

    private func createTabs(app: XCUIApplication, count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            app.typeKey("t", modifierFlags: .command)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUXD_DISABLE"] = "1"
        return app
    }
}

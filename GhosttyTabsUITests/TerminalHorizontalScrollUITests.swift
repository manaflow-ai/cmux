import XCTest

final class TerminalHorizontalScrollUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTerminalHorizontalScrollDoesNotOffsetView() {
        let app = makeApp()
        app.launch()
        app.activate()

        let offset = app.descendants(matching: .any)["TerminalScrollOffset"].firstMatch
        XCTAssertTrue(offset.waitForExistence(timeout: 5.0))

        let terminal = app.descendants(matching: .any)["TerminalSurfaceView"].firstMatch
        if terminal.waitForExistence(timeout: 2.0) {
            runScrollAssertions(on: terminal, app: app, offsetElement: offset)
            return
        }

        let fallback = app.descendants(matching: .any)["TerminalScrollView"].firstMatch
        if fallback.waitForExistence(timeout: 2.0) {
            runScrollAssertions(on: fallback, app: app, offsetElement: offset)
            return
        }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2.0))
        runScrollAssertions(on: window, app: app, offsetElement: offset)
    }

    private func runScrollAssertions(on terminal: XCUIElement, app: XCUIApplication, offsetElement: XCUIElement) {
        terminal.click()
        let longLine = String(repeating: "0123456789", count: 20)
        app.typeText(longLine)

        terminal.scroll(byDeltaX: -800, deltaY: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        terminal.scroll(byDeltaX: 800, deltaY: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let offsetX = extractOffsetX(from: offsetElement.value)
        XCTContext.runActivity(named: "Terminal horizontal offset") { activity in
            let attachment = XCTAttachment(string: String(format: "offsetX=%.1f", offsetX))
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        XCTAssertEqual(offsetX, 0.0, accuracy: 0.5)
    }

    private func extractOffsetX(from value: Any?) -> Double {
        guard let value = value as? String else { return 0 }
        let parts = value.split(separator: " ")
        for part in parts where part.hasPrefix("x=") {
            return Double(part.dropFirst(2)) ?? 0
        }
        return 0
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUXD_DISABLE"] = "1"
        return app
    }
}

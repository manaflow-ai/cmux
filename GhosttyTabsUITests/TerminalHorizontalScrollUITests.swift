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
        _ = offset.waitForExistence(timeout: 1.0)

        guard let target = resolveScrollTarget(app: app) else { return }
        runScrollAssertions(on: target, app: app, offsetElement: offset)
    }

    private func runScrollAssertions(on terminal: XCUIElement, app: XCUIApplication, offsetElement: XCUIElement) {
        terminal.click()
        let longLine = String(repeating: "0123456789", count: 20)
        app.typeText(longLine)

        terminal.scroll(byDeltaX: -800, deltaY: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        terminal.scroll(byDeltaX: 800, deltaY: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let offsetX = extractOffsetX(from: metricsString(app: app, offsetElement: offsetElement))
        XCTContext.runActivity(named: "Terminal horizontal offset") { activity in
            let attachment = XCTAttachment(string: String(format: "offsetX=%.1f", offsetX))
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        XCTAssertEqual(offsetX, 0.0, accuracy: 0.5)
    }

    private func metricsString(app: XCUIApplication, offsetElement: XCUIElement) -> String? {
        let candidates: [XCUIElement] = [
            offsetElement,
            app.descendants(matching: .any)["TerminalScrollView"].firstMatch,
            app.descendants(matching: .any)["TerminalSurfaceView"].firstMatch,
        ]
        for element in candidates {
            if let value = element.value as? String, value.contains("x=") {
                return value
            }
            let label = element.label
            if label.contains("x=") {
                return label
            }
            if let value = element.value as? String, !value.isEmpty {
                return value
            }
            if !label.isEmpty {
                return label
            }
        }
        return nil
    }

    private func extractOffsetX(from value: String?) -> Double {
        guard let value else { return 0 }
        let parts = value.split(separator: " ")
        for part in parts where part.hasPrefix("x=") {
            return Double(part.dropFirst(2)) ?? 0
        }
        return 0
    }

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["CMUXD_DISABLE"] = "1"
        return app
    }

    private func resolveScrollTarget(app: XCUIApplication) -> XCUIElement? {
        _ = app.wait(for: .runningForeground, timeout: 10.0)
        let window = app.windows.firstMatch
        let terminal = app.descendants(matching: .any)["TerminalSurfaceView"].firstMatch
        if terminal.waitForExistence(timeout: 12.0) {
            return terminal
        }
        let fallback = app.descendants(matching: .any)["TerminalScrollView"].firstMatch
        if fallback.waitForExistence(timeout: 8.0) {
            return fallback
        }
        if window.exists {
            return window
        }
        app.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        app.typeKey("n", modifierFlags: .command)
        if terminal.waitForExistence(timeout: 10.0) {
            return terminal
        }
        if fallback.waitForExistence(timeout: 10.0) {
            return fallback
        }
        if window.exists {
            return window
        }
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("Terminal view not found")
        return nil
    }
}

import XCTest

/// Regression fixture for cmux#57025: a downward drag over a mouse-mode
/// full-screen app sends its wheel to the PTY while the phone-side
/// ``TerminalTUIReader`` stays closed.
final class TerminalTUIDragScrollsTheAppUITests: XCTestCase {
    @MainActor
    func testDownwardDragSendsWheelToPTYWithoutOpeningReader() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += [
            "-cmuxMobile.setupComplete", "YES",
            "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
            "-CmuxMobileTerminalDemoPhases", "tuipan-mouse",
        ]
        app.launch()
        defer { app.terminate() }

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
        var demo = ""
        var deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !demo.hasPrefix("tuipan-mouse ready") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            demo = probe.label
        }
        XCTAssertTrue(demo.hasPrefix("tuipan-mouse ready"), "the mouse-mode fixture is up: \(demo)")

        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        start.press(forDuration: 0.02, thenDragTo: end,
                    withVelocity: XCUIGestureVelocity(900), thenHoldForDuration: 0)

        deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !demo.hasPrefix("tuipan-mouse done") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            demo = probe.label
        }
        XCTAssertTrue(demo.hasPrefix("tuipan-mouse done"), "the drag phase finished: \(demo)")

        let values = Self.values(demo)
        XCTAssertTrue(demo.contains("isTUI=true"), "the fixture is the full-screen app: \(demo)")
        XCTAssertGreaterThan(values["bytes"] ?? 0, 0, "the drag sent wheel bytes to the PTY: \(demo)")
        XCTAssertGreaterThan(values["appScrolls"] ?? 0, 0, "the full-screen app consumed the wheel: \(demo)")
        XCTAssertEqual(values["readerOpened"] ?? -1, 0, "the phone-side TUI reader never opened: \(demo)")
        XCTAssertTrue(demo.contains("reader=closed"), "the phone-side TUI reader stayed closed: \(demo)")
    }

    private static func values(_ label: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for word in label.split(separator: " ") {
            let pair = word.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let value = Int(pair[1]) {
                out[String(pair[0])] = value
            }
        }
        return out
    }
}

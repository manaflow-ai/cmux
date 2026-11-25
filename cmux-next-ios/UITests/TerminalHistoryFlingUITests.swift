import XCTest

/// Leo, 2026-11-21: "this claude code cli is often slow to scroll up and down
/// from ios". A Mac terminal attaches with its latest rows first; the
/// reader's first fling up reaches the top of them and asks for the older
/// rows, which come back as a mirror reset and a replay of the whole window.
/// The reset stops a fling to place the reader, so asking mid-fling cut the
/// first fling up short. The terminal demo's `historyfling` phase flings up
/// into the top of a mock history window: the fling runs to its end (no
/// reset stops it) and the older rows are still asked for.
final class TerminalHistoryFlingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testFlingIntoTheTopOfTheHistoryWindowRunsToItsEnd() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "historyfling"]
        app.launch()
        defer { app.terminate() }

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
        var demo = ""
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !demo.hasPrefix("historyfling done") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            demo = probe.label
        }
        // The readout as a text attachment: a UI test's print never reaches
        // the step's exported logs, its attachments do.
        let numbers = XCTAttachment(string: "history-fling \(demo)\n")
        numbers.name = "history-fling-numbers"
        numbers.lifetime = .keepAlways
        add(numbers)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "history-fling-end"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(demo.hasPrefix("historyfling done"), "the phase finished: \(demo)")

        let values = Self.values(demo)
        XCTAssertGreaterThanOrEqual(values["fetches"] ?? 0, 1, "the fling near the top asked for the older rows: \(demo)")
        XCTAssertEqual(values["stopped"] ?? -1, 0, "no reset stopped the fling: \(demo)")
    }

    /// `key=N` words of the demo's label.
    private static func values(_ label: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for word in label.split(separator: " ") {
            let pair = word.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let value = Int(pair[1]) { out[String(pair[0])] = value }
        }
        return out
    }
}

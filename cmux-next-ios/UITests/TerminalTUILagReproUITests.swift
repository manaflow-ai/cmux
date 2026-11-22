import XCTest

/// Leo, 2026-11-22: "just off some basic scroll throughs of the tui on my
/// phone, the thing still lags. cosmic-gray on ethernet, iphone on wifi ...
/// if the data was sent through... why cant you simply scroll through the
/// depiction that was already given?" His load, not a fixture: the terminal
/// demo's `tuipan-paged` phase runs Claude Code on the primary screen of a
/// Mac terminal (12,000 styled rows with SGR colors and wide characters on
/// the Mac; the phone starts with the screen alone and pages older rows in
/// 2,000 at a time, a reset and a replay of every row held a 60 ms round
/// trip later, as `DaemonTerminalSession` does) with its live region redrawn
/// every 80 ms throughout. This test flings up through the history for 5 s
/// and back down for 5 s with one finger; the app measures every display
/// frame from the first touch to 4 s after the last: frame time p50, p95 and
/// max, hitches, frames over 33 ms, stalls over 50 ms, the time the page sat
/// on the oldest row held waiting for older ones, and the longest frames
/// against the replays. It records numbers and fails only when the phase
/// did not run (the readout is the evidence, not a gate).
final class TerminalTUILagReproUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor func testOneFingerScrollThroughPagedClaudeCodeHistoryWhileItStreams() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "tuipan-paged"]
        app.launch()
        defer { app.terminate() }

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
        var demo = ""
        var deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !demo.hasPrefix("tuipan-paged ready") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            demo = probe.label
        }
        XCTAssertTrue(demo.hasPrefix("tuipan-paged ready"), "the mock Claude Code is up: \(demo)")

        // A thumb reading back: quick flings toward older rows for 5 s (each
        // one into the top of the rows held asks the Mac for older ones),
        // then back toward the newest for 5 s.
        let window = app.windows.firstMatch
        let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        var drags = 0
        for older in [true, false] {
            let end = Date().addingTimeInterval(5)
            while Date() < end {
                (older ? high : low).press(forDuration: 0.02, thenDragTo: older ? low : high,
                                          withVelocity: XCUIGestureVelocity(2500), thenHoldForDuration: 0)
                drags += 1
            }
        }

        deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !demo.hasPrefix("tuipan-paged done") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            demo = probe.label
        }
        // The readout as a text attachment: a UI test's print never reaches
        // the step's exported logs, its attachments do.
        let numbers = XCTAttachment(string: "tui-lag-repro \(demo) drags=\(drags)\n")
        numbers.name = "tui-lag-repro-paged"
        numbers.lifetime = .keepAlways
        add(numbers)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "tui-lag-repro-paged-end"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(demo.hasPrefix("tuipan-paged done"), "the phase finished: \(demo)")
        XCTAssertTrue(demo.contains("isTUI=false"), "Claude Code is on the primary screen: \(demo)")
        XCTAssertGreaterThan(Self.values(demo)["frames"] ?? 0, 60, "frames were measured while the finger panned: \(demo)")
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

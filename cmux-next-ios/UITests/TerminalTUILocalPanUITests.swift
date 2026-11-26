import XCTest

/// Leo, 2026-11-22 06:04Z: "just off some basic scroll throughs of the tui
/// on my phone, the thing still lags", and 2026-11-12: "surely we're not
/// regressing behavior, right? Like, you can still scroll through things and
/// click on things and whatnot". A one-finger pan over a full-screen app
/// scrolls the app (its wheel, sent to the Mac); over the primary screen it
/// scrolls what the phone already holds and sends nothing. The terminal
/// demo's `tuipan` phases run a mock Claude Code (`primary`: the primary
/// screen with its live region redrawn every 80 ms; `mouse`: its
/// full-screen mode on the alternate screen with the mouse asked for;
/// `keys`: the same without the mouse) and measure while this test pans with
/// one finger for 10 s: frame time p50, p95 and max, hitches, main-thread
/// stalls, the bytes and sends the phone made (one send per main-queue
/// turn, as `DaemonTerminalSession` batches) and the most sends in a frame.
final class TerminalTUILocalPanUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor func testOneFingerPanOverClaudeCodeOnThePrimaryScreenSendsNothing() throws {
        try pan(variant: "primary")
    }

    @MainActor func testOneFingerPanOverAFullScreenAppWithTheMouseScrollsTheApp() throws {
        try pan(variant: "mouse")
    }

    @MainActor func testOneFingerPanOverAFullScreenAppWithoutTheMouseScrollsTheApp() throws {
        try pan(variant: "keys")
    }

    // Under duress (Leo, 2026-11-22: "testing under duress"): 12,000 styled
    // rows and output streaming every 16 ms while the finger pans.

    @MainActor func testOneFingerPanOverClaudeCodeOnThePrimaryScreenUnderLoadSendsNothing() throws {
        try pan(variant: "primary-load")
    }

    @MainActor func testOneFingerPanOverAStreamingFullScreenAppWithTheMouseScrollsTheApp() throws {
        try pan(variant: "mouse-load")
    }

    @MainActor func testOneFingerPanOverAStreamingFullScreenAppWithoutTheMouseScrollsTheApp() throws {
        try pan(variant: "keys-load")
    }

    // Leo, 2026-11-23: "we should also be able to smooth out the jaggedness of scroll that we have in
    // claude in terminal vs in regular shell terminal. latter feels smoother for some reason." A slow
    // drag, as a reader reads: the shell's page moves a few points a frame; the full-screen app moved
    // nothing for several frames and then three rows (a whole wheel report's redraw) in one. The demo
    // reads where the content was drawn each frame (`stepP95Pct`: the 95th percentile frame's move as a
    // percent of a row; `stillPct`: frames, between the first move and the last, where nothing moved).

    @MainActor func testSlowDragOverTheShellPageMovesItSmoothly() throws {
        let values = try pan(variant: "primary-slow", velocity: 200)
        XCTAssertGreaterThan(values["motionFrames"] ?? 0, 30, "the page moved under the finger")
    }

    @MainActor func testSlowDragOverAFullScreenAppMovesItsRowsSmoothly() throws {
        let values = try pan(variant: "mouse-slow", velocity: 200)
        XCTAssertGreaterThan(values["motionFrames"] ?? 0, 30, "the app's rows moved")
        XCTAssertLessThan(values["stepP95Pct"] ?? 1000, 100, "no frame (p95) moves the rows a whole row or more")
        XCTAssertLessThan(values["stillPct"] ?? 100, 50, "the rows move in most frames, not stand still between jumps")
    }

    @discardableResult @MainActor
    private func pan(variant: String, velocity: CGFloat = 900) throws -> [String: Int] {
        let primary = variant.hasPrefix("primary")
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "tuipan-\(variant)"]
        app.launch()
        defer { app.terminate() }

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
        var demo = ""
        var deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !demo.hasPrefix("tuipan-\(variant) ready") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            demo = probe.label
        }
        XCTAssertTrue(demo.hasPrefix("tuipan-\(variant) ready"), "the mock Claude Code is up: \(demo)")

        // 10 s of one finger: drags toward older rows and back, each
        // released moving (a fling), as a thumb reads through a transcript.
        let window = app.windows.firstMatch
        let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        let panEnd = Date().addingTimeInterval(10)
        var drags = 0
        while Date() < panEnd {
            let older = (drags / 3) % 2 == 0
            (older ? high : low).press(forDuration: 0.02, thenDragTo: older ? low : high,
                                      withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: 0)
            drags += 1
        }

        deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !demo.hasPrefix("tuipan-\(variant) done") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            demo = probe.label
        }
        // The readout as a text attachment: a UI test's print never reaches
        // the step's exported logs, its attachments do.
        let numbers = XCTAttachment(string: "tui-local-pan \(demo) drags=\(drags)\n")
        numbers.name = "tui-local-pan-\(variant)"
        numbers.lifetime = .keepAlways
        add(numbers)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "tui-local-pan-\(variant)-end"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(demo.hasPrefix("tuipan-\(variant) done"), "the phase finished: \(demo)")

        let values = Self.values(demo)
        XCTAssertTrue(demo.contains(primary ? "isTUI=false" : "isTUI=true"), "the mock is on the screen it emulates: \(demo)")
        XCTAssertGreaterThan(values["frames"] ?? 0, 60, "frames were measured while the finger panned: \(demo)")
        if primary {
            XCTAssertEqual(values["bytes"] ?? -1, 0, "a one-finger pan over the primary screen sent the Mac nothing: \(demo)")
            XCTAssertEqual(values["appScrolls"] ?? -1, 0, "nothing scrolled the app: \(demo)")
        } else {
            XCTAssertGreaterThan(values["appScrolls"] ?? 0, 0, "a one-finger drag scrolled the full-screen app: \(demo)")
            XCTAssertGreaterThan(values["bytes"] ?? 0, 0, "its wheel went to the Mac: \(demo)")
        }
        return values
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

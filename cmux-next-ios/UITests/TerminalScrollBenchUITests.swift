import XCTest

/// Leo, 2026-11-21: "terminals are indeed fast now... but only the bare
/// ones. this claude code cli is often slow to scroll up and down from ios."
/// The terminal demo's `scrollbench` phase flings the same scrollback up and
/// down on a bare shell, then while a mock of Claude Code's inline screen
/// redraws below it, then with its clear-and-reprint too, then a mock of its
/// full-screen mode (the drag is the wheel; each report redraws the screen,
/// 30 ms after it leaves the phone), and reports each case's frame intervals.
/// Scrolling under the agent's redraws keeps the bare shell's pace: p95
/// within 1.5 frames of the bare case.
final class TerminalScrollBenchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testScrollingUnderAnInlineAgentKeepsTheBareShellsPace() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "scrollbench", "-cmux-mobile-term-rtt-ms", "30"]
        app.launch()
        defer { app.terminate() }

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
        var demo = ""
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !demo.hasPrefix("scrollbench done") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            demo = probe.label
        }
        print("scroll-bench \(demo)")
        // The numbers as a text attachment too: a UI test's print never
        // reaches the step's exported logs, its attachments do.
        let numbers = XCTAttachment(string: "scroll-bench \(demo)\n")
        numbers.name = "scroll-bench-numbers"
        numbers.lifetime = .keepAlways
        add(numbers)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "scroll-bench-end"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(demo.hasPrefix("scrollbench done"), "the bench finished: \(demo)")

        let p95 = Self.values(demo, "p95")
        let bare = try XCTUnwrap(p95["bare"], demo)
        // 1.5 frames at the simulator's rate: a case that misses frames the
        // bare shell does not is slower than it.
        let frame = 1000.0 / 120
        for name in ["claude-inline", "claude-inline-reprint", "claude-inline-long", "claude-full"] {
            let value = try XCTUnwrap(p95[name], demo)
            XCTAssertLessThanOrEqual(value, max(bare, frame) + frame * 0.5, "\(name): p95 \(value) ms against the bare shell's \(bare) ms")
        }
        // The full-screen flings reached the app as wheel reports.
        XCTAssertGreaterThan(Self.values(demo, "wheel")["claude-full"] ?? 0, 0, "claude-full: the flings scrolled the app (\(demo))")
    }

    /// `bench NAME frames=.. p50=.. p95=..` parts of the demo's label: NAME to the key's value.
    private static func values(_ label: String, _ key: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for part in label.components(separatedBy: " | ") {
            let words = part.split(separator: " ")
            guard let at = words.firstIndex(of: "bench"), at + 1 < words.count else { continue }
            let name = String(words[at + 1])
            for word in words where word.hasPrefix(key + "=") {
                out[name] = Double(word.dropFirst(key.count + 1))
            }
        }
        return out
    }
}

import XCTest

/// Leo, 2026-11-24: "sometimes the highlights in terminal just float and dont move when i
/// scroll?" A full-screen app (Claude Code's full-screen mode, vim) has no scrollback on the
/// phone: when it scrolls its screen, a highlight held as screen rows stayed where it was,
/// over whatever text came there. The terminal demo's `highlight` phases run a mock Claude
/// Code in that mode with a highlight up: `find` searches "lorem" and this test's finger
/// scrolls the app; `select` selects "transcript row N" while the app's streamed reply
/// scrolls it. The demo reads the highlights back as drawn to the text under them.
final class TerminalHighlightScrollUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor func testFindHighlightsMoveWithTheTextWhenTheFingerScrollsAFullScreenApp() throws {
        let demo = try run(variant: "find") { app in
            // Drags toward older rows and back over the top of the screen (the find bar's
            // keyboard covers the bottom), each wheel moving the app's text.
            let window = app.windows.firstMatch
            let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22))
            let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
            for drag in 0..<4 {
                let older = drag != 2
                (older ? high : low).press(forDuration: 0.05, thenDragTo: older ? low : high,
                                          withVelocity: XCUIGestureVelocity(500), thenHoldForDuration: 0.2)
            }
        }
        let values = Self.values(demo)
        XCTAssertGreaterThan(values["appScrolls"] ?? 0, 0, "the finger scrolled the full-screen app: \(demo)")
        XCTAssertGreaterThan(values["on"] ?? 0, 0, "matches on the screen are highlighted: \(demo)")
        XCTAssertEqual(values["off"] ?? -1, 0, "no find highlight was left over other text: \(demo)")
        XCTAssertEqual(values["missed"] ?? -1, 0, "every match on the screen is highlighted: \(demo)")
    }

    @MainActor func testASelectionMovesWithItsTextWhenAFullScreenAppScrollsItself() throws {
        let demo = try run(variant: "select") { _ in }
        XCTAssertGreaterThan(Self.values(demo)["appScrolls"] ?? 0, 0, "the streamed reply scrolled the app: \(demo)")
        XCTAssertTrue(demo.contains("sel=on"), "the selection is still on its text: \(demo)")
    }

    @MainActor
    private func run(variant: String, gesture: (XCUIApplication) -> Void) throws -> String {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "highlight-\(variant)"]
        app.launch()
        defer { app.terminate() }

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
        var demo = ""
        var deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !demo.hasPrefix("highlight-\(variant) ready"), !demo.hasPrefix("highlight-\(variant) done") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            demo = probe.label
        }
        let ready = demo
        XCTAssertTrue(demo.contains("isTUI=true"), "the mock Claude Code is up in its full-screen mode: \(demo)")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "highlight-\(variant)-before"
        before.lifetime = .keepAlways
        add(before)

        gesture(app)

        deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !demo.hasPrefix("highlight-\(variant) done") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            demo = probe.label
        }
        // A UI test's print never reaches the step's exported logs; its attachments do.
        let numbers = XCTAttachment(string: "\(ready)\n\(demo)\n")
        numbers.name = "highlight-\(variant)"
        numbers.lifetime = .keepAlways
        add(numbers)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "highlight-\(variant)-after"
        after.lifetime = .keepAlways
        add(after)
        XCTAssertTrue(demo.hasPrefix("highlight-\(variant) done"), "the phase finished: \(demo)")
        return demo
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

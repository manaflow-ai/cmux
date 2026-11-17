import XCTest

/// Leo, 2026-11-17: "how's the lean terminal view on phone? proven upholding
/// behaviour yet? headers left right end of terminal lines etc?"
///
/// Leo, 2026-11-15: "you just need to prove the behaviour is full with the
/// projection style or whatever and then it's gtg".
///
/// Mac-versus-phone screenshots of every golden case of the terminal
/// projection (cmux-tui/crates/cmux-terminal-projection/tests/golden.rs):
/// the app feeds the case's recorded program bytes (the golden's `vt/NAME.vt`)
/// from a Mac pane at the case's grid, `-CmuxMobileProjectionGolden NAME`
/// (TerminalProjectionGoldenDemo.swift). Each case runs twice:
///
/// - `mac`: the bytes on a page at the Mac's grid, scaled to the screen
///   (landscape): what the Mac pane shows.
/// - `phone`: the real projecting session on the real terminal page, portrait.
///
/// One screenshot per golden stage (`NAME-SIDE-STAGE`), each with the
/// surface's rows as text (`NAME-SIDE-STAGE.txt`) to read against the golden.
/// `rotation_and_keyboard` adds keyboard up, keyboard down, landscape and
/// portrait again on the phone. The shots gate nothing: they are the proof
/// a person reads.
final class TerminalProjectionGoldenShotsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor func testHeadersClaudeCode() { both("headers_claude_code") }
    @MainActor func testHeadersCodex() { both("headers_codex") }
    @MainActor func testLeftAndRightAligned() { both("left_and_right_aligned") }
    @MainActor func testLineEndsSoftAndHard() { both("line_ends_soft_and_hard") }
    @MainActor func testWideCJKAndEmoji() { both("wide_cjk_and_emoji") }
    @MainActor func testColorsAcrossWraps() { both("colors_and_attributes_across_wraps") }
    @MainActor func testCursorPositions() { both("cursor_positions") }
    @MainActor func testAlternateScreenCodex() { both("alternate_screen_codex_and_back") }
    @MainActor func testLiveStreaming() { both("live_streaming_output") }
    @MainActor func testScrollback() { both("scrollback_reaches_line_one") }
    @MainActor func testRotationAndKeyboard() { both("rotation_and_keyboard") }

    @MainActor
    private func both(_ name: String) {
        run(name, side: "mac")
        run(name, side: "phone")
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func run(_ name: String, side: String, scrollToTop: Bool = true) {
        XCUIDevice.shared.orientation = side == "mac" ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES",
                                "-CmuxMobileProjectionGolden", name, "-CmuxMobileProjectionGoldenSide", side,
                                "-CmuxMobileProjectionGoldenScrollToTop", scrollToTop ? "YES" : "NO"]
        app.launch()
        defer { app.terminate() }
        let probe = app.staticTexts["debug.terminal-demo"]
        let text = app.staticTexts["debug.golden-text"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the golden demo's step label\n\(app.debugDescription)")
        let prefix = "golden.\(name).\(side)."

        func shot(_ stage: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(name)-\(side)-\(stage)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let rows = XCTAttachment(string: text.exists ? text.label : "-")
            rows.name = "\(name)-\(side)-\(stage).txt"
            rows.lifetime = .keepAlways
            add(rows)
        }

        var seen: Set<String> = []
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let label = probe.label
            if label.hasPrefix(prefix) {
                let stage = String(label.dropFirst(prefix.count))
                if stage == "done" { break }
                if !stage.hasPrefix("0."), !seen.contains(stage) {
                    seen.insert(stage)
                    // `1.welcome` -> `1-welcome`
                    shot(stage.replacingOccurrences(of: ".", with: "-"))
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(probe.label == prefix + "done", "\(name) \(side) never finished: \(probe.label)")
        XCTAssertFalse(seen.isEmpty, "\(name) \(side): no stage on screen")

        if side == "phone", name == "rotation_and_keyboard" {
            XCUIDevice.shared.orientation = .landscapeLeft
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            shot("9-landscape")
            XCUIDevice.shared.orientation = .portrait
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            shot("10-portrait-again")
        }

        if side == "phone", name == "scrollback_reaches_line_one", !scrollToTop {
            // Real swipes toward the top, one a second, for at most 30 s:
            // the reader scrolling up brings the older rows until line 1.
            let window = app.windows.firstMatch
            let deadline = Date().addingTimeInterval(120)
            var swipes = 0
            var afterLoaded = -1
            while Date() < deadline, afterLoaded < 10 {
                let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                let to = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
                swipes += 1
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                if swipes % 5 == 0 { shot("swipe-\(swipes)") }
                if afterLoaded >= 0 {
                    afterLoaded += 1
                } else if text.exists, text.label.contains("|line 0001") {
                    print("[projection-golden] line 0001 held after \(swipes) swipes")
                    afterLoaded = 0
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            shot("swiped-top")
            print("[projection-golden] swipes \(swipes) head: \(text.exists ? String(text.label.prefix(600)) : "-")")
            XCTAssertTrue(text.exists && text.label.contains("head") && text.label.contains("|line 0001"), "line 0001 is not the phone's first row after \(swipes) swipes")
        }
    }

    @MainActor func testScrollbackSwipesPhone() { run("scrollback_reaches_line_one", side: "phone", scrollToTop: false) }
}

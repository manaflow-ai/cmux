import XCTest

/// Leo, 2026-11-23: "i want to be able to click (tap) the top bit of the
/// terminal in phone to jump to that last sent bit. making it clickable would
/// be good cuz then i can properly use the phone to examine stuff", and
/// "making the jump to bottom be more clickable and having that click not also
/// register as me somehow tapping into that chat box of the terminal".
///
/// On a workspace's zsh tab with the mock session: send `cargo build` from the
/// composer, scroll away from it, tap the strip at the top, land on its row
/// (marked for a moment). Jump to bottom: a bigger target, and neither its tap
/// nor a second tap where it was focuses the terminal or the composer.
final class TerminalLastSentStripUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTapTopStripJumpsToLastSentLine() throws {
        let app = launch()
        send(app, "cargo build")
        let strip = app.buttons["terminal.lastSentStrip"]
        // The build log may push the prompt above the page already; else scroll away from it.
        if !strip.waitForExistence(timeout: 3) {
            XCTAssertTrue(scroll(app, up: true, until: strip), "away from the sent line: the top strip shows\n\(app.debugDescription)")
        }
        XCTAssertTrue(strip.label.contains("cargo build"), "the strip shows the sent line: \(strip.label)")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(strip.frame.minY, window.height * 0.2, "the strip is the top bit of the terminal: \(strip.frame)")
        XCTAssertGreaterThanOrEqual(strip.frame.height, 44, "a 44 pt target at least: \(strip.frame)")
        attach(app, "strip-shown")

        strip.tap()
        Thread.sleep(forTimeInterval: 0.15)
        attach(app, "strip-gliding")
        XCTAssertTrue(strip.waitForNonExistence(timeout: 5), "landed on the sent line: the strip hides")
        let mark = app.descendants(matching: .any)["terminal.lastSentHighlight"]
        XCTAssertTrue(mark.waitForExistence(timeout: 2), "the landed row is marked\n\(app.debugDescription)")
        XCTAssertGreaterThan(mark.frame.height, 4, "the mark is a row: \(mark.frame)")
        XCTAssertLessThan(mark.frame.minY, window.height * 0.35, "the sent line lands near the top: \(mark.frame)")
        XCTAssertGreaterThan(mark.frame.minY, strip.frame.minY - 60, "under the status bar: \(mark.frame)")
        attach(app, "landed-on-sent-line")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the strip's tap is not a tap into the terminal")
    }

    @MainActor
    func testJumpToBottomTapNeverFocusesComposerOrTerminal() throws {
        let app = launch()
        let jump = app.buttons["terminal.jumpToBottom"]
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(scroll(app, up: true, until: jump), "scrolled up: Jump to bottom shows\n\(app.debugDescription)")
        XCTAssertGreaterThanOrEqual(jump.frame.height, 60, "a bigger target than the 56 pt before: \(jump.frame)")
        let spot = jump.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        attach(app, "pill-before-tap")
        spot.tap()
        // A second tap where the pill was, as a person does when the first felt missed.
        spot.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "the tap went to the bottom")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "no keyboard: neither tap went into the terminal or the composer")
        XCTAssertNotEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true, "the composer did not take the focus")
        attach(app, "after-double-tap")

        // A near miss just above the pill is not a tap into the terminal either.
        XCTAssertTrue(scroll(app, up: true, until: jump), "scrolled up again")
        jump.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -8)).tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a near miss above the pill shows no keyboard")
        XCTAssertNotEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true, "a near miss does not focus the composer")
    }

    // MARK: Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
        app.launch()
        XCTAssertTrue(app.textViews["terminal.composer.field"].waitForExistence(timeout: 20), "composer field\n\(app.debugDescription)")
        return app
    }

    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) {
        let field = app.textViews["terminal.composer.field"]
        field.tap()
        field.typeText(text)
        app.buttons["terminal.composer.send"].tap()
        if app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            app.descendants(matching: .any)["terminal.key.keyboard"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the keyboard went down")
        }
        // The build log runs for a few seconds.
        Thread.sleep(forTimeInterval: 4)
    }

    @MainActor
    private func scroll(_ app: XCUIApplication, up: Bool, until target: XCUIElement) -> Bool {
        let (from, to): (CGFloat, CGFloat) = up ? (0.3, 0.7) : (0.7, 0.3)
        for _ in 0..<12 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
            if target.waitForExistence(timeout: 1) { return true }
        }
        return false
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

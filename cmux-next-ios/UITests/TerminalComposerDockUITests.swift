import XCTest

/// The terminal's key row follows the soft keyboard. Return in the
/// composer starts a new line, the compose key reveals,
/// closes and reopens the composer, and Hide Toolbar folds the dock until the
/// next terminal tap. Runs on a workspace's terminal tab as the app shows it
/// (TabsKit chrome), with mock sign-in and the mock terminal session.
final class TerminalComposerDockUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDockFollowsClassicComposerRules() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
        app.launch()

        let field = app.textViews["terminal.composer.field"]
        let composeKey = app.buttons["terminal.key.composer"]
        let keyboardKey = app.buttons["terminal.key.keyboard"]
        let control = app.buttons["terminal.key.control"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "composer field\n\(app.debugDescription)")

        XCTAssertFalse(keyboardKey.exists, "the key row is hidden at rest")
        attach(app, "rest")

        // Return in the field starts a new line; it does not send.
        field.tap()
        XCTAssertTrue(keyboardKey.waitForExistence(timeout: 5))
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        XCTAssertLessThan(control.frame.maxY, field.frame.minY, "the key row sits above the composer")
        XCTAssertEqual(keyboardKey.label, "Hide Keyboard")
        field.typeText("echo one\nls")
        XCTAssertEqual(field.value as? String, "echo one\nls", "Return inserted a new line")

        // Shown and focused: the compose key closes the composer; the key row stays.
        composeKey.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "compose key closes a focused composer")
        XCTAssertTrue(control.exists, "the key row outlives the composer")
        attach(app, "closed")

        // Closed: the compose key opens it again, focused, with the draft kept.
        composeKey.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "echo one\nls", "the draft survives close and reopen")

        // Hide Toolbar folds the key row and the composer; a terminal tap brings them back.
        let hide = app.buttons["Hide Toolbar"]
        // Drag the key row's scroller (right of the pinned keys) to its end.
        let window = app.windows.firstMatch.frame
        let rowY = (keyboardKey.frame.midY - window.minY) / window.height
        // 44 pt keys: the row is ~1900 pt wide, so a few more drags than the old 28 pt row took.
        for _ in 0..<16 where !(hide.exists && hide.isHittable) {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: rowY))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: rowY)))
        }
        XCTAssertTrue(hide.waitForHittable(timeout: 5), "Hide Toolbar at the row's end\n\(app.debugDescription)")
        hide.tap()
        XCTAssertTrue(composeKey.waitForNonExistence(timeout: 5), "Hide Toolbar hides the key row")
        XCTAssertFalse(field.exists, "and the composer")
        attach(app, "hidden")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(composeKey.waitForExistence(timeout: 5), "a terminal tap reveals the dock")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "echo one\nls", "and the draft is still there")
        attach(app, "revealed")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

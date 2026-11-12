import XCTest

/// CMUX-10: the terminal's Jump to bottom button sits centered (as it first
/// shipped, and as the agent chat's jump circle does), in its own row above
/// the key row and below the terminal's rows, not between the key row and the
/// composer,
/// and Settings → Terminal → Jump to Bottom Button removes it. Runs on a
/// workspace's zsh tab with the mock session, whose intro (ls, git log, a
/// build log) leaves scrollback to scroll up into. The full-screen app rule
/// (never in vim) is the pure `JumpToBottomVisibility.showsInTerminal` rule,
/// covered by `TerminalJumpToBottomTests`.
final class TerminalJumpToBottomUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testJumpToBottomIsCentered() throws {
        let app = launch()
        let jump = app.buttons["terminal.jumpToBottom"]
        let field = app.textViews["terminal.composer.field"]

        XCTAssertTrue(scrollUp(app, until: jump), "scrolled up: Jump to bottom shows\n\(app.debugDescription)")
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(jump.frame.width, window.width / 2, "the element is the pill, not the full-width row")
        XCTAssertEqual(jump.frame.midX, window.midX, accuracy: 2, "Jump to bottom is centered (was trailing)")
        XCTAssertLessThan(jump.frame.maxY, field.frame.minY, "it sits above the composer field")
        let keyRow = app.descendants(matching: .any)["terminal.key.keyboard"]
        XCTAssertTrue(keyRow.exists, "the key row shows\n\(app.debugDescription)")
        XCTAssertLessThanOrEqual(jump.frame.maxY, keyRow.frame.minY,
                                 "Jump to bottom sits above the key row (was between it and the composer): jump \(jump.frame) keys \(keyRow.frame)")
        attach(app, "scrolled-up-centered")

        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "a tap goes to the bottom and hides it")
        attach(app, "after-jump")
    }

    /// Keyboard up, the stack rides the keyboard: the pill stays above the
    /// key row, centered.
    @MainActor
    func testJumpToBottomAboveKeyRowWithKeyboardUp() throws {
        let app = launch()
        let field = app.textViews["terminal.composer.field"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard shows")
        let jump = app.buttons["terminal.jumpToBottom"]
        XCTAssertTrue(scrollUp(app, until: jump), "scrolled up with the keyboard up: Jump to bottom shows\n\(app.debugDescription)")
        let keyRow = app.descendants(matching: .any)["terminal.key.keyboard"]
        XCTAssertLessThanOrEqual(jump.frame.maxY, keyRow.frame.minY, "above the key row: jump \(jump.frame) keys \(keyRow.frame)")
        XCTAssertEqual(jump.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2, "centered")
        attach(app, "keyboard-up-scrolled-up")
    }

    /// Hide Toolbar folds the key row and the composer; scrolled up, the pill
    /// is the stack's only row, on the solid backing (not over the rows).
    @MainActor
    func testJumpToBottomWithHideToolbar() throws {
        let app = launch()
        let keyboardKey = app.descendants(matching: .any)["terminal.key.keyboard"]
        let hide = app.buttons["Hide Toolbar"]
        let window = app.windows.firstMatch.frame
        let rowY = (keyboardKey.frame.midY - window.minY) / window.height
        for _ in 0..<8 where !(hide.exists && hide.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: rowY))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: rowY)))
        }
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "Hide Toolbar at the row's end\n\(app.debugDescription)")
        hide.tap()
        XCTAssertTrue(keyboardKey.waitForNonExistence(timeout: 5), "Hide Toolbar hides the key row")
        let jump = app.buttons["terminal.jumpToBottom"]
        XCTAssertTrue(scrollUp(app, until: jump), "scrolled up with the toolbar hidden: Jump to bottom shows\n\(app.debugDescription)")
        XCTAssertEqual(jump.frame.midX, window.midX, accuracy: 2, "centered")
        attach(app, "hide-toolbar-scrolled-up")
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "a tap goes to the bottom and hides it")
        attach(app, "hide-toolbar-after-jump")
    }

    @MainActor
    func testSettingOffRemovesJumpToBottom() throws {
        // Control: with the setting on, the same scroll shows it.
        let on = launch()
        XCTAssertTrue(scrollUp(on, until: on.buttons["terminal.jumpToBottom"]), "control: shows with the setting on")
        on.terminate()

        let app = launch(extraArguments: ["-cmuxMobile.settings.terminalJumpToBottom", "NO"])
        let jump = app.buttons["terminal.jumpToBottom"]
        XCTAssertFalse(scrollUp(app, until: jump), "Settings → Terminal → Jump to Bottom Button off removes it")
        attach(app, "setting-off-scrolled-up")
    }

    @MainActor
    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"] + extraArguments
        app.launch()
        XCTAssertTrue(app.textViews["terminal.composer.field"].waitForExistence(timeout: 20), "composer field\n\(app.debugDescription)")
        return app
    }

    /// Drags the rows down (content scrolls up) until `target` shows: up to
    /// 12 drags, each followed by a short wait on the element itself, so the
    /// mock intro's scrollback has time to stream in.
    @MainActor
    private func scrollUp(_ app: XCUIApplication, until target: XCUIElement) -> Bool {
        for _ in 0..<12 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
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

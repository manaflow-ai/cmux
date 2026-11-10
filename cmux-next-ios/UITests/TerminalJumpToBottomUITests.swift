import XCTest

/// CMUX-10: the terminal's Jump to bottom button sits centered above the
/// composer (as it first shipped, and as the agent chat's jump circle does),
/// shows only in scroll mode (never in a full-screen app such as vim), and
/// Settings → Terminal → Jump to Bottom Button removes it. Runs on a
/// workspace's zsh tab with the mock session, whose intro (ls, git log, a
/// build log) leaves scrollback to scroll up into.
final class TerminalJumpToBottomUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testJumpToBottomIsCenteredAndOnlyInScrollMode() throws {
        let app = launch()
        let jump = app.buttons["terminal.jumpToBottom"]
        let field = app.textViews["terminal.composer.field"]

        scrollUp(app, until: jump)
        XCTAssertTrue(jump.waitForExistence(timeout: 5), "scrolled up: Jump to bottom shows\n\(app.debugDescription)")
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(jump.frame.midX, window.midX, accuracy: 2, "Jump to bottom is centered (was trailing)")
        XCTAssertLessThan(jump.frame.maxY, field.frame.minY, "it sits above the composer field")
        attach(app, "scrolled-up-centered")

        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "a tap goes to the bottom and hides it")
        attach(app, "after-jump")

        // A full-screen app owns its scrolling: no Jump to bottom there.
        field.tap()
        field.typeText("vim")
        app.buttons["terminal.composer.send"].tap()
        let terminal = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        for _ in 0..<3 {
            terminal.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        }
        XCTAssertFalse(jump.waitForExistence(timeout: 2), "never in a full-screen app (vim)")
        attach(app, "vim-no-jump")
    }

    @MainActor
    func testSettingOffRemovesJumpToBottom() throws {
        let app = launch(extraArguments: ["-cmuxMobile.settings.terminalJumpToBottom", "NO"])
        let jump = app.buttons["terminal.jumpToBottom"]
        scrollUp(app, until: jump)
        XCTAssertFalse(jump.waitForExistence(timeout: 2), "Settings → Terminal → Jump to Bottom Button off removes it")
        attach(app, "setting-off-scrolled-up")
    }

    @MainActor
    private func launch(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"] + extraArguments
        app.launch()
        XCTAssertTrue(app.textViews["terminal.composer.field"].waitForExistence(timeout: 20), "composer field\n\(app.debugDescription)")
        // The mock session's intro streams a build log: wait for scrollback.
        _ = app.staticTexts["never"].waitForExistence(timeout: 6)
        return app
    }

    /// Drags the rows down (content scrolls up) until `target` shows, or 6 drags.
    @MainActor
    private func scrollUp(_ app: XCUIApplication, until target: XCUIElement) {
        for _ in 0..<6 where !target.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

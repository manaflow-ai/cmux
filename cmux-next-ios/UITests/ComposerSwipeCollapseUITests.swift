import XCTest

/// Leo, 2026-11-22: "chatgpt you csn swipe down inside the composer to collapse it. we need that here too."
/// A downward swipe that starts inside the composer's text takes the keyboard away (`ComposerSwipeCollapse`,
/// on `ComposerReturnTextView`), in the terminal's composer and in the agent chat's.
final class ComposerSwipeCollapseUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSwipeDownInsideTerminalComposerCollapsesIt() throws {
        try swipeCollapses(demo: "ws-terminal-idle", field: "terminal.composer.field")
    }

    @MainActor
    func testSwipeDownInsideChatComposerCollapsesIt() throws {
        try swipeCollapses(demo: "kbd-chat", field: "chat.composer.field")
    }

    // MARK: Steps

    @MainActor
    private func swipeCollapses(demo: String, field id: String) throws {
        let app = launch(demo: demo)
        defer { app.terminate() }
        let field = app.textViews[id]
        if !field.waitForExistence(timeout: 30) { app.buttons["agentChat.composer.collapsed"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "composer field \(id)\n\(app.debugDescription)")
        focus(app, field)
        field.typeText("draft")
        attach(app, "\(demo)-keyboard-up")
        swipeDown(inside: field)
        XCTAssertTrue(waitForNoKeyboard(app), "a swipe down inside the composer takes the keyboard away")
        attach(app, "\(demo)-collapsed")
        XCTAssertEqual(field.value as? String, "draft", "collapsing keeps the draft")

        // And back: a tap brings the keyboard again, and a second swipe collapses again.
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "a tap brings the keyboard back")
        swipeDown(inside: field)
        XCTAssertTrue(waitForNoKeyboard(app), "a second swipe collapses it again")
    }

    @MainActor
    private func launch(demo: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // The swipe is off by default (Settings → Composer → Swipe Down to Collapse): turn it on.
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmuxMobile.settings.swipeDownCollapsesComposer", "YES",
                                "-cmux-mobile-demo", demo]
        app.launch()
        return app
    }

    @MainActor
    private func focus(_ app: XCUIApplication, _ field: XCUIElement) {
        if !app.keyboards.firstMatch.exists { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard comes up")
    }

    /// A quick downward drag that starts inside the field's text (no rest before it moves: a rest is the loupe).
    @MainActor
    private func swipeDown(inside field: XCUIElement) {
        let from = field.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.3))
        let to = from.withOffset(CGVector(dx: 0, dy: 90))
        from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
    }

    @MainActor
    private func waitForNoKeyboard(_ app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        let gone = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [expectation(for: gone, evaluatedWith: app.keyboards.firstMatch)],
                                timeout: timeout) == .completed
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

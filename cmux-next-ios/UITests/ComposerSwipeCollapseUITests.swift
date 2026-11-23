import XCTest

/// Leo, 2026-11-22: "chatgpt you csn swipe down inside the composer to collapse it. we need that here too."
/// A downward swipe that starts inside the composer's text takes the keyboard away (`ComposerSwipeCollapse`,
/// on `ComposerReturnTextView`), in the terminal's composer and in the agent chat's.
///
/// The thumb-reach check beside it measures, in the terminal composer, the two controls a thumb reaches for
/// while typing: Send and the key row's keyboard key (hide the keyboard). For a draft of 1 line and of 6
/// lines it records each control's frame and whether one tap reaches it (on screen and hittable), and
/// attaches the table as `thumb-reach.txt`. It reports; only a control no tap reaches fails it.
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

    @MainActor
    func testThumbReachAtOneAndSixLines() throws {
        let app = launch(demo: "ws-terminal-idle")
        defer { app.terminate() }
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "terminal composer field\n\(app.debugDescription)")
        focus(app, field)
        field.typeText("one")
        settle()
        let send = app.buttons["terminal.composer.send"].firstMatch
        let hide = app.descendants(matching: .any)["terminal.key.keyboard"].firstMatch
        let one = (send: reach(send), hide: reach(hide), field: field.frame)
        attach(app, "reach-1-line")

        for line in 2...6 { field.typeText("\nline \(line)") }
        settle()
        let six = (send: reach(send), hide: reach(hide), field: field.frame)
        attach(app, "reach-6-lines")

        var rows = ["control        lines  taps  frame (x, y, w, h) pt          moved from 1 line"]
        func row(_ name: String, _ lines: Int, _ r: Reach, _ base: Reach) {
            let moved = String(format: "dx %.0f dy %.0f", r.frame.midX - base.frame.midX, r.frame.midY - base.frame.midY)
            rows.append(String(format: "%@  %d      %@     (%.0f, %.0f, %.0f, %.0f)   %@",
                               name.padding(toLength: 13, withPad: " ", startingAt: 0), lines,
                               r.taps.map(String.init) ?? "-", r.frame.minX, r.frame.minY, r.frame.width,
                               r.frame.height, moved))
        }
        row("send", 1, one.send, one.send)
        row("send", 6, six.send, one.send)
        row("hide keyboard", 1, one.hide, one.hide)
        row("hide keyboard", 6, six.hide, one.hide)
        rows.append(String(format: "composer field height: %.0f pt at 1 line, %.0f pt at 6 lines",
                           one.field.height, six.field.height))
        attachText("thumb-reach", rows.joined(separator: "\n"))

        XCTAssertGreaterThan(six.field.height, one.field.height + 20, "the composer grew with the draft")
        for (name, r) in [("send, 1 line", one.send), ("send, 6 lines", six.send),
                          ("hide keyboard, 1 line", one.hide), ("hide keyboard, 6 lines", six.hide)] {
            XCTAssertEqual(r.taps, 1, "\(name): one tap reaches it (\(r.frame))\n\(rows.joined(separator: "\n"))")
        }
        // The swipe is the second way down, at 6 lines too (the draft fits, so its text is at the top).
        swipeDown(inside: field)
        XCTAssertTrue(waitForNoKeyboard(app), "a swipe down inside a 6-line draft collapses the composer")
    }

    // MARK: Steps

    @MainActor
    private func swipeCollapses(demo: String, field id: String) throws {
        let app = launch(demo: demo)
        defer { app.terminate() }
        let field = app.textViews[id]
        if !field.waitForExistence(timeout: 30) { app.buttons["Reply to Claude"].firstMatch.tap() }
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
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo]
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

    private struct Reach {
        var frame: CGRect
        /// 1 when one tap reaches it where it is; nil when it is off screen or covered.
        var taps: Int?
    }

    @MainActor
    private func reach(_ element: XCUIElement) -> Reach {
        guard element.exists else { return Reach(frame: .zero, taps: nil) }
        return Reach(frame: element.frame, taps: element.isHittable ? 1 : nil)
    }

    @MainActor
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

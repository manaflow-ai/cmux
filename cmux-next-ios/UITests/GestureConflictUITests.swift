import XCTest

/// The gesture matrix's cells (`cmux-next-ios/design/gesture-matrix.md`), each a real touch on the
/// shipping app's offline DEBUG demos, asserting which view moved and which did not.
///
/// Leo, 2026-11-23: "when i try to scroll in the composer in ios it ... swipes the entire thing
/// down instead of scrolling through the composer. there are no doubt dozens of ... interactions
/// like this which should've just very easily been caught and understood and iterated on."
///
/// Every cell is one test named `test<Surface>_<Region>_<Gesture>_<Outcome>`, so a red names the
/// conflict. A new gesture on a surface adds its cell here and in the matrix.
final class GestureConflictUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: Composer: a vertical drag through a long draft scrolls the draft

    /// The pushed agent chat (internal dock): dragging a long draft down to read its start keeps
    /// the keyboard up and the composer where it is; only the text moves.
    @MainActor
    func testChat_ComposerLongDraft_DragDown_ScrollsText() {
        let app = launch(demo: "kbd-chat")
        let field = openChatComposer(app)
        field.typeText(Self.longDraft)
        assertDragScrollsText(app, field)
    }

    /// The agent chat as a workspace tab (the external dock under the toolbar).
    @MainActor
    func testWorkspaceChat_ComposerLongDraft_DragDown_ScrollsText() {
        let app = launch(demo: "kbd-tab")
        let field = openChatComposer(app)
        field.typeText(Self.longDraft)
        assertDragScrollsText(app, field)
    }

    /// The terminal composer with a nine-line draft (scrolled to its caret).
    @MainActor
    func testTerminal_ComposerLongDraft_DragDown_ScrollsText() {
        let app = launch(demo: "ws-terminal-composer", env: ["CMUX_MOBILE_DEMO_COMPOSER": "long"])
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal composer\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        expect(app.keyboards.firstMatch, "exists == true", "the keyboard comes up")
        assertDragScrollsText(app, field)
    }

    /// The other half of the rule: with a one-line draft (nothing to scroll), a downward swipe on
    /// the composer still lowers the keyboard, as in Messages and ChatGPT.
    @MainActor
    func testChat_ComposerShortDraft_SwipeDown_LowersKeyboard() {
        let app = launch(demo: "kbd-chat")
        let field = openChatComposer(app)
        field.typeText("short")
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 140)))
        expect(app.keyboards.firstMatch, "exists == false", "a swipe down on a short draft lowers the keyboard")
        attach(app, "short-after-swipe")
    }

    // MARK: Back swipe: never from text being edited

    /// A rightward drag inside the terminal composer while editing moves the caret or selects;
    /// the workspace's full-width back swipe (iOS 26 content pop) must not take it and leave.
    @MainActor
    func testTerminal_ComposerEditing_SwipeRight_StaysInWorkspace() {
        let app = launch(demo: "ws-terminal-composer", env: ["CMUX_MOBILE_DEMO_COMPOSER": "short"])
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal composer\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        expect(app.keyboards.firstMatch, "exists == true", "the keyboard comes up")
        assertSwipeRightStays(app, field)
    }

    /// The same in the agent chat as a workspace tab.
    @MainActor
    func testWorkspaceChat_ComposerEditing_SwipeRight_StaysInWorkspace() {
        let app = launch(demo: "kbd-tab")
        let field = openChatComposer(app)
        field.typeText("move the caret along this line")
        assertSwipeRightStays(app, field)
    }

    @MainActor
    private func assertSwipeRightStays(_ app: XCUIApplication, _ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let from = field.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 220, dy: 0)), withVelocity: .fast,
                   thenHoldForDuration: 0.05)
        // A pop would have animated the workspace away by now.
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "after-swipe-right")
        XCTAssertTrue(field.exists && field.isHittable, "still in the workspace with the composer open", file: file, line: line)
    }

    // MARK: Feed: a row's swipe actions and taps leave the touched view its gesture

    /// Cell 35: a leftward drag along a reply being typed moves the caret or selects; the row's
    /// trailing swipe actions stay shut.
    @MainActor
    func testFeed_ReplyField_SwipeLeft_StaysOnText() {
        let app = launch(demo: "kbd-feed")
        let (list, field) = openFeedReply(app)
        field.typeText("a reply long enough to drag the caret along")
        let from = field.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -200, dy: 0)), withVelocity: .fast,
                   thenHoldForDuration: 0.05)
        Thread.sleep(forTimeInterval: 0.6)
        attach(app, "feed-reply-after-swipe-left")
        XCTAssertFalse(list.buttons["Done"].exists, "the row's swipe actions stay shut")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stays up: the drag was the text's")
    }

    /// Cell 38: a tap in the reply field puts the caret there; the row never opens its chat.
    @MainActor
    func testFeed_ReplyField_Tap_StaysInFeed() {
        let app = launch(demo: "kbd-feed")
        let (list, field) = openFeedReply(app)
        field.typeText("one two three")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.8)
        attach(app, "feed-reply-after-tap")
        XCTAssertTrue(list.exists && field.exists && field.isHittable, "still on the Feed with the reply open")
    }

    @MainActor
    private func openFeedReply(_ app: XCUIApplication) -> (XCUIElement, XCUIElement) {
        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 30), "the Feed\n\(app.debugDescription)")
        let reply = list.buttons["Reply"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "a row's Reply\n\(app.debugDescription)")
        reply.tap()
        let field = list.textViews["feed.reply.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the row's reply field\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        expect(app.keyboards.firstMatch, "exists == true", "the keyboard comes up")
        return (list, field)
    }

    // MARK: Helpers

    /// About ten wrapped lines at the 17 pt body on a phone: taller than the field's six.
    static let longDraft = (1...14).map { "Line \($0) of a long draft" }.joined(separator: " ")

    @MainActor
    private func assertDragScrollsText(_ app: XCUIApplication, _ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        // Typing at the end leaves the draft scrolled to its bottom.
        attach(app, "1-long-draft")
        let frameBefore = field.frame
        let textBefore = field.screenshot().pngRepresentation
        // Down inside the field, staying inside it: the reader pulls the draft's start into view.
        let top = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let bottom = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        top.press(forDuration: 0.05, thenDragTo: bottom, withVelocity: .slow, thenHoldForDuration: 0.1)
        attach(app, "2-after-drag")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stays up: the drag was the draft's scroll", file: file, line: line)
        XCTAssertTrue(field.exists, "the composer stays open", file: file, line: line)
        XCTAssertEqual(field.frame.minY, frameBefore.minY, accuracy: 2, "the composer did not move", file: file, line: line)
        XCTAssertNotEqual(field.screenshot().pngRepresentation, textBefore, "the draft's text scrolled", file: file, line: line)
    }

    @MainActor
    private func openChatComposer(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textViews["chat.composer.field"]
        if !field.waitForExistence(timeout: 30) { app.buttons["Reply to Claude"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the composer field\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        expect(app.keyboards.firstMatch, "exists == true", "the keyboard comes up")
        return field
    }

    @MainActor
    private func launch(demo: String, env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        for (k, v) in env { app.launchEnvironment[k] = v }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo]
        app.launch()
        addTeardownBlock { app.terminate() }
        return app
    }

    @MainActor
    private func expect(_ element: XCUIElement, _ predicate: String, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed, message)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

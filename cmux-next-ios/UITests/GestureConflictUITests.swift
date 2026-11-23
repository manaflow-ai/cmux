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

    // MARK: Tabs: the toolbar and the overview keep their own drags and pinches (cluster A)

    /// Cell 15: a rightward drag along the toolbar's capsule is the bar swipe between tabs; the
    /// workspace's full-width back swipe must not take it and leave the workspace.
    @MainActor
    func testTabs_Toolbar_SwipeRight_StaysInWorkspace() {
        let app = launch(demo: "ws-terminal-idle")
        let workspace = app.descendants(matching: .any)["workspace.ws-cmux"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 30), "the workspace\n\(app.debugDescription)")
        let tabs = tabsButton(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "the toolbar's Tabs button\n\(app.debugDescription)")
        // The capsule's middle: the screen's centre at the Tabs button's height.
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.frame.width * 0.3, dy: tabs.frame.midY))
        attach(app, "1-before-bar-swipe")
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 200, dy: 0)), withVelocity: .fast,
                   thenHoldForDuration: 0.05)
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "2-after-bar-swipe")
        XCTAssertTrue(workspace.exists, "still in the workspace: the drag was the bar swipe")
        XCTAssertTrue(tabs.isHittable, "the toolbar is still there")
    }

    /// Cell 16: a rightward drag on an overview card is the card's swipe (rubber band, springs
    /// back); the back swipe must not leave the workspace, and the card stays.
    @MainActor
    func testTabs_OverviewCard_SwipeRight_StaysInWorkspace() {
        let app = launch(demo: "ws-terminal-idle")
        let tabs = tabsButton(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 30), "the toolbar's Tabs button\n\(app.debugDescription)")
        tabs.tap()
        let cards = app.buttons.matching(NSPredicate(format: "label ENDSWITH ', tab'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 15), "grid cards\n\(app.debugDescription)")
        let count = cards.count
        let card = cards.firstMatch
        let from = card.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        attach(app, "1-grid")
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 160, dy: 0)), withVelocity: .fast,
                   thenHoldForDuration: 0.05)
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "2-after-card-swipe")
        XCTAssertTrue(app.descendants(matching: .any)["workspace.ws-cmux"].exists, "still in the workspace")
        XCTAssertEqual(cards.count, count, "a rightward card swipe closes nothing")
    }

    /// Cell 14: a pinch on the toolbar is no page's, so it never zooms the page out to the grid.
    @MainActor
    func testTabs_Toolbar_Pinch_KeepsPage() {
        let app = launch(demo: "ws-terminal-idle")
        let tabs = tabsButton(app)
        XCTAssertTrue(tabs.waitForExistence(timeout: 30), "the toolbar's Tabs button\n\(app.debugDescription)")
        tabs.pinch(withScale: 0.4, velocity: -2)
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "after-toolbar-pinch")
        let cards = app.buttons.matching(NSPredicate(format: "label ENDSWITH ', tab'"))
        XCTAssertFalse(cards.firstMatch.exists, "the grid did not open from a pinch on the toolbar")
        XCTAssertTrue(tabs.isHittable, "the page and its toolbar stay")
    }

    @MainActor
    private func tabsButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'")).firstMatch
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

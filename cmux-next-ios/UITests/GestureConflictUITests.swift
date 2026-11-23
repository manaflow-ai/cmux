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

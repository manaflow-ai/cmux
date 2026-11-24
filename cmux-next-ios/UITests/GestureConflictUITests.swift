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
        field.tap() // the field, not the terminal behind it, takes the keyboard: it is being edited
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

    /// The third cell: a long draft scrolled back to its top has nothing left to scroll down to,
    /// so the next swipe down lowers the keyboard (the text keeps every drag until then).
    @MainActor
    func testChat_ComposerLongDraftAtTop_SwipeDown_LowersKeyboard() {
        let app = launch(demo: "kbd-chat")
        let field = openChatComposer(app)
        field.typeText(Self.longDraft)
        let top = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let bottom = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        // One drag the field's height scrolls the draft (about three lines past the field) to its
        // start, and it is the text's, so the keyboard stays. A second drag would already start at
        // the top, where the swipe is the dock's.
        top.press(forDuration: 0.05, thenDragTo: bottom, withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "scrolling the draft to its top keeps the keyboard up; \(state(app, field))")
        attach(app, "long-at-top")
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 160)), withVelocity: .fast,
                    thenHoldForDuration: 0)
        expect(app.keyboards.firstMatch, "exists == false", "a swipe down on a draft at its top lowers the keyboard")
        attach(app, "long-at-top-after-swipe")
    }

    // MARK: Back swipe: never from text being edited

    /// A rightward drag inside the terminal composer while editing moves the caret or selects;
    /// the workspace's full-width back swipe (iOS 26 content pop) must not take it and leave.
    @MainActor
    func testTerminal_ComposerEditing_SwipeRight_StaysInWorkspace() {
        let app = launch(demo: "ws-terminal-composer", env: ["CMUX_MOBILE_DEMO_COMPOSER": "short"])
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the terminal composer\n\(app.debugDescription)")
        field.tap() // the field, not the terminal behind it, takes the keyboard: it is being edited
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
        let page = app.descendants(matching: .any)["workspace.ws-cmux"]
        XCTAssertTrue(page.exists, "the workspace page is open; \(state(app, field))", file: file, line: line)
        let frameBefore = field.frame
        let from = field.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 220, dy: 0)), withVelocity: .fast,
                   thenHoldForDuration: 0.05)
        // A pop would have animated the workspace away by now, and the drawer slid it aside.
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "after-swipe-right")
        // The field may sit under its own edit menu after the drag selected text, so it is the
        // page and the field's place that tell, not whether a tap would reach the field.
        XCTAssertTrue(page.exists && field.exists, "still in the workspace with the composer open; \(state(app, field))", file: file, line: line)
        XCTAssertEqual(field.frame.minX, frameBefore.minX, accuracy: 2,
                       "the workspace did not slide aside (was \(NSCoder.string(for: frameBefore))); \(state(app, field))", file: file, line: line)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the composer is still being edited; \(state(app, field))", file: file, line: line)
    }

    // MARK: Helpers

    /// What the screen holds, for a failure message: the log shows it when the run's
    /// attachments cannot be read.
    @MainActor
    private func state(_ app: XCUIApplication, _ field: XCUIElement) -> String {
        let fields = app.textViews.allElementsBoundByIndex.prefix(6).map { "\($0.identifier)@\(Int($0.frame.minY))" }
        let buttons = app.buttons.allElementsBoundByIndex.prefix(24).map(\.label).filter { !$0.isEmpty }
        let menus = app.menuItems.allElementsBoundByIndex.prefix(8).map(\.label)
        let ids = app.otherElements.allElementsBoundByIndex.prefix(40).filter { !$0.identifier.isEmpty }
            .prefix(12).map { "\($0.identifier)@\(NSCoder.string(for: $0.frame))" }
        return "field exists=\(field.exists) hittable=\(field.exists && field.isHittable) frame=\(field.exists ? NSCoder.string(for: field.frame) : "-") "
            + "keyboard=\(app.keyboards.firstMatch.exists) textViews=\(fields) menus=\(menus) views=\(ids) buttons=\(buttons)"
    }

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
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stays up: the drag was the draft's scroll; \(state(app, field))", file: file, line: line)
        XCTAssertTrue(field.exists, "the composer stays open; \(state(app, field))", file: file, line: line)
        XCTAssertEqual(field.frame.minY, frameBefore.minY, accuracy: 2, "the composer did not move; \(state(app, field))", file: file, line: line)
        XCTAssertNotEqual(field.screenshot().pngRepresentation, textBefore, "the draft's text scrolled; \(state(app, field))", file: file, line: line)
    }

    @MainActor
    private func openChatComposer(_ app: XCUIApplication) -> XCUIElement {
        let field = app.textViews["chat.composer.field"]
        // At rest the workspace tab's composer is its collapsed capsule; a tap opens the field. A tap
        // while the tab is still settling can land before the capsule takes taps, so it is retried.
        let capsule = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
        for _ in 0..<3 where !field.waitForExistence(timeout: 10) {
            if capsule.waitForExistence(timeout: 20), capsule.isHittable { capsule.tap() }
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "the composer field; capsule exists=\(capsule.exists); \(state(app, field))")
        field.tap() // the field, not the terminal behind it, takes the keyboard: it is being edited
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

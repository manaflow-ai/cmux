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

    // MARK: Artifacts: wide code inside the multi-file pager (cell 11)

    /// A leftward drag on code wider than the phone scrolls the code; the gallery stays on the
    /// first file.
    @MainActor
    func testArtifactGallery_WideCode_SwipeLeft_ScrollsCode() {
        let app = launch(demo: "code-gallery")
        expectPosition(app, "1 of 2")
        let before = app.screenshot().pngRepresentation
        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: -160, dy: 0)), withVelocity: .slow,
                     thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.8)
        attach(app, "code-after-swipe-left")
        XCTAssertEqual(visiblePosition(app), "1 of 2", "the code's own scroll took the drag, not the file pager")
        XCTAssertNotEqual(app.screenshot().pngRepresentation, before, "the code scrolled sideways")
    }

    /// Once the code sits at its trailing edge, the next leftward drag pages to the next file.
    @MainActor
    func testArtifactGallery_WideCodeAtEdge_SwipeLeft_PagesFiles() {
        let app = launch(demo: "code-gallery")
        expectPosition(app, "1 of 2")
        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        var swipes = 0
        while visiblePosition(app) == "1 of 2", swipes < 16 {
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: -260, dy: 0)), withVelocity: .fast,
                         thenHoldForDuration: 0)
            swipes += 1
            Thread.sleep(forTimeInterval: 0.8)
        }
        attach(app, "code-at-edge-paged")
        XCTAssertEqual(visiblePosition(app), "2 of 2", "a drag past the code's edge pages")
        XCTAssertGreaterThan(swipes, 1, "the first drag scrolled the code, not the pager")
    }

    /// A leftward swipe on the title bar (outside the code) pages at once.
    @MainActor
    func testArtifactGallery_TitleBar_SwipeLeft_PagesFiles() {
        let app = launch(demo: "code-gallery")
        expectPosition(app, "1 of 2")
        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the gallery's bar")
        let from = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -240, dy: 0)), withVelocity: .fast,
                   thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 0.8)
        attach(app, "title-paged")
        XCTAssertEqual(visiblePosition(app), "2 of 2", "a swipe outside the code pages")
    }

    // MARK: Lists: the keyboard follows the finger (cell 41)

    /// With the workspaces search keyboard up, a short scroll of the results keeps the keyboard
    /// (interactive dismissal); `.onDrag` lowered it on any drag.
    @MainActor
    func testWorkspaces_SearchResults_DragUp_KeepsKeyboard() {
        let app = launch(demo: nil, args: ["-cmux-mobile-tab", "workspaces"])
        let list = app.collectionViews["workspaces.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 30), "the workspaces list\n\(app.debugDescription)")
        app.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "the search field")
        search.tap()
        expect(app.keyboards.firstMatch, "exists == true", "the keyboard comes up")
        app.typeText("c")
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -120)), withVelocity: .slow,
                   thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 0.6)
        attach(app, "search-after-drag-up")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "a scroll that never reached the keyboard keeps it up")
    }

    // MARK: Sheets: the list scrolls before the sheet grows (cell 49), a draft is never dragged away (cell 50)

    /// New Agent Chat With… at the medium height: an upward drag on its list scrolls the list;
    /// the sheet (its bar) stays where it is.
    @MainActor
    func testWorkspace_AgentChooserSheet_DragUp_ScrollsListFirst() {
        let app = launch(demo: nil, args: ["-cmux-mobile-tab", "workspaces"])
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the ws-cmux row\n\(app.debugDescription)")
        row.tap()
        Thread.sleep(forTimeInterval: 1.5)
        app.buttons["Tabs"].firstMatch.tap()
        let new = app.buttons["New"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10), "the grid's New")
        new.tap()
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "New Agent Chat With")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "New Agent Chat With…")
        item.tap()
        let start = app.buttons["agentChooser.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), "the chooser sheet")
        let harness = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "agentChooser.harness.")).firstMatch
        XCTAssertTrue(harness.waitForExistence(timeout: 15), "the chooser's harness rows")
        Thread.sleep(forTimeInterval: 0.8)
        let barBefore = start.frame.minY
        attach(app, "chooser-medium")
        let from = harness.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -200)), withVelocity: .slow,
                   thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "chooser-after-drag-up")
        XCTAssertEqual(start.frame.minY, barBefore, accuracy: 4, "the sheet stayed at its height: the list took the drag")
    }

    /// Send Message… with a draft: a drag down on the sheet does not dismiss it, and the draft
    /// is still there (SPEC 4.8: swipe down dismisses unless the sheet holds unsaved input).
    @MainActor
    func testMessageChiefSheet_Draft_DragDown_KeepsDraft() {
        let app = launch(demo: nil, args: ["-cmux-mobile-tab", "workspaces"])
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the ws-cmux row\n\(app.debugDescription)")
        row.press(forDuration: 1.0)
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Send Message")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Send Message…")
        item.tap()
        // A vertical-axis TextField: a text view or a text field, by OS version.
        let field = app.descendants(matching: .any)["chief.messageAbout.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the message field\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        expect(app.keyboards.firstMatch, "exists == true", "the keyboard comes up")
        app.typeText("look at the transport change")
        let bar = app.navigationBars["Message Chief"]
        XCTAssertTrue(bar.exists, "the sheet's bar")
        let from = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 500)), withVelocity: .fast,
                   thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 1.2)
        attach(app, "message-sheet-after-drag-down")
        XCTAssertTrue(field.exists, "the sheet is still open")
        XCTAssertTrue((field.value as? String ?? "").contains("transport change"), "the draft is kept")
    }

    // MARK: Helpers

    /// The gallery's "N of M" on the page in view (the pager keeps its neighbour's too).
    @MainActor
    private func visiblePosition(_ app: XCUIApplication) -> String? {
        let screen = app.windows.firstMatch.frame
        let labels = app.staticTexts.matching(identifier: "artifact.position").allElementsBoundByIndex
        return labels.first { screen.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }?.label
    }

    @MainActor
    private func expectPosition(_ app: XCUIApplication, _ position: String) {
        let deadline = Date().addingTimeInterval(30)
        while visiblePosition(app) != position, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertEqual(visiblePosition(app), position, "the code gallery\n\(app.debugDescription)")
        // The highlighted lines land after the page appears.
        Thread.sleep(forTimeInterval: 1.0)
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
    private func launch(demo: String?, args: [String] = [], env: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        for (k, v) in env { app.launchEnvironment[k] = v }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES"] + args
        if let demo { app.launchArguments += ["-cmux-mobile-demo", demo] }
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

import XCTest

/// Leo, 2026-11-23: "for ios, holding shouldnt raise the whole bubble of a chunk of text being
/// selected / just hold and it should highlight text as normal then you select some bits".
///
/// A hold on an answer's text selects the word under the finger in place (a range, with the edit
/// menu's Copy), a drag while held extends it, and nothing lifts: no context menu, no Select Text
/// sheet, no whole block. (CMUX-33 had a context menu whose Select Text opened a sheet.)
///
/// Both transcript paths: the native rows (standard text size) and the SwiftUI rows (every row
/// at accessibility sizes).
final class ChatSelectTextUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testHoldOnAnswerSelectsAWordInPlaceNativeRows() {
        run(name: "native", arguments: [])
    }

    @MainActor
    func testHoldOnAnswerSelectsAWordInPlaceSwiftUIRows() {
        run(name: "swiftui", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"])
    }

    @MainActor
    private func run(name: String, arguments: [String]) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "disclosure-chat"] + arguments
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.navigationBars.buttons["More"].firstMatch.waitForExistence(timeout: 30),
                      "the pushed agent chat opens\n\(app.debugDescription)")
        // The newest answer's first paragraph, near the bottom where the chat opens. Small drags
        // only: scrolling up into the earlier turns' incoming agent-message cards crashes the
        // base app (a SwiftUI stack overflow in AgentSenderIcon while the list prefetches).
        let lead = "The transport switch holds up"
        let paragraph = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", lead)).firstMatch
        let window = app.windows.firstMatch
        // Fully below the navigation bar: `isHittable` holds for a paragraph half under the bar,
        // and a press at its center then lands on the bar.
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        func clear() -> Bool { paragraph.exists && paragraph.frame.minY > barBottom + 8 && paragraph.frame.maxY < window.frame.maxY - 140 }
        for _ in 0..<6 where !clear() {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: paragraph.exists ? 120 : 180)))
        }
        XCTAssertTrue(clear(), "the answer paragraph is fully on screen\n\(app.debugDescription)")
        let paragraphFrame = paragraph.frame

        // Hold on "transport", the first line's second word (about 50 pt in), and lift.
        let word = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: paragraphFrame.minX + 50, dy: paragraphFrame.minY + 10))
        word.press(forDuration: 1.2)
        let selection = app.textViews["chat.inPlaceSelection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5),
                      "a hold selects the answer's text in place\n\(app.debugDescription)")
        let selected = selection.label
        XCTAssertFalse(selected.isEmpty, "a range is selected")
        XCTAssertFalse(selected.contains(" "), "the hold selects one word, not the block: \(selected)")
        XCTAssertTrue(lead.contains(selected), "the word under the finger is selected: \(selected)")
        // Nothing lifted: no context menu's rows, no Select Text sheet.
        XCTAssertFalse(app.buttons["Select Text"].exists, "no context menu lifted the row\n\(app.debugDescription)")
        XCTAssertFalse(app.navigationBars["Select text"].exists, "no Select Text sheet")
        XCTAssertTrue(editMenuCopy(app).waitForExistence(timeout: 5), "the edit menu offers Copy\n\(app.debugDescription)")
        attach(app, "\(name)-hold-selects-word")

        // A hold then a drag right along the line selects some words: more than one, less than the block.
        let again = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: paragraphFrame.minX + 10, dy: paragraphFrame.minY + 10))
        again.press(forDuration: 1.0, thenDragTo: again.withOffset(CGVector(dx: 150, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(selection.waitForExistence(timeout: 5), "the selection is still in place\n\(app.debugDescription)")
        let dragged = selection.label
        XCTAssertTrue(dragged.contains(" "), "a drag while held extends the selection word by word: \(dragged)")
        XCTAssertTrue(lead.hasPrefix(dragged) || dragged.count < lead.count + 20, "only some of the text is selected: \(dragged)")
        XCTAssertFalse(app.buttons["Select Text"].exists, "still no lifted menu")
        attach(app, "\(name)-hold-drag-selects-some")

        // A tap beside it clears the selection, and the text is drawn as before.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: paragraphFrame.midX, dy: paragraphFrame.maxY + 60)).tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: selection)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(paragraph.exists, "the paragraph shows again")
    }

    @MainActor
    private func editMenuCopy(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == 'Copy' AND (elementType == %d OR elementType == %d)",
            XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue
        )).firstMatch
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

import XCTest

/// Leo, 2026-11-23 (ask-18247cdaa6): "for ios, holding shouldnt raise the whole bubble of a chunk
/// of text being selected / just hold and it should highlight text as normal then you select some bits".
///
/// The SwiftUI transcript (every row at accessibility text sizes, where SwiftUI `Text` has no word
/// selection): a hold on an answer selects the word under the finger in place, a drag while held
/// extends it to some words, and nothing lifts (no context menu, no Select Text sheet, no whole
/// block). The native rows' cells are ChatHoldSelectsWordUITests (#52600).
final class SwiftUIHoldSelectsTextUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testHoldOnAnswerSelectsAWordInPlaceSwiftUIRows() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "disclosure-chat",
                                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.navigationBars.buttons["More"].firstMatch.waitForExistence(timeout: 30),
                      "the pushed agent chat opens\n\(app.debugDescription)")
        let lead = "The transport switch holds up"
        let paragraph = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", lead)).firstMatch
        let window = app.windows.firstMatch
        let clear = { paragraph.exists && paragraph.frame.minY > 140 && paragraph.frame.minY + 40 < window.frame.maxY - 120 }
        for _ in 0..<12 where !clear() {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: paragraph.exists ? 120 : 180)))
        }
        XCTAssertTrue(clear(), "the answer paragraph is on screen\n\(app.debugDescription)")
        let frame = paragraph.frame
        attach(app, "swiftui-before-hold")

        // Hold on "transport" (about 60 pt in on the first line at this size) and lift.
        let word = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 60, dy: frame.minY + 14))
        word.press(forDuration: 1.2)
        let selection = app.textViews["chat.inPlaceSelection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5), "a hold selects the answer's text in place\n\(app.debugDescription)")
        let selected = selection.label
        XCTAssertFalse(selected.isEmpty, "a range is selected")
        XCTAssertFalse(selected.contains(" "), "the hold selects one word, not the block: \(selected)")
        XCTAssertFalse(app.buttons["Select Text"].exists, "no context menu lifted the row\n\(app.debugDescription)")
        XCTAssertFalse(app.navigationBars["Select text"].exists, "no Select Text sheet")
        XCTAssertTrue(editMenuCopy(app).waitForExistence(timeout: 5), "the edit menu offers Copy\n\(app.debugDescription)")
        attach(app, "swiftui-hold-selects-word")

        // Hold then drag right: some words, not the block.
        let again = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 10, dy: frame.minY + 14))
        again.press(forDuration: 1.0, thenDragTo: again.withOffset(CGVector(dx: 150, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(selection.waitForExistence(timeout: 5), "the selection is still in place\n\(app.debugDescription)")
        let dragged = selection.label
        XCTAssertTrue(dragged.contains(" "), "a drag while held extends the selection: \(dragged)")
        XCTAssertLessThan(dragged.count, 120, "only some of the text is selected: \(dragged)")
        XCTAssertFalse(app.buttons["Select Text"].exists, "still no lifted menu")
        attach(app, "swiftui-hold-drag-selects-some")

        // A tap beside it clears the selection; the paragraph is drawn as before.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: max(frame.minY - 60, 150))).tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: selection)
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

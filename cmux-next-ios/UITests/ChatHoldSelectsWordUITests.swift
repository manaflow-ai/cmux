import XCTest

/// Leo, 2026-11-23: holding on chat text should not lift the whole bubble or select a chunk of text;
/// it should highlight text as normal, then you adjust the selection. A long press on a word in an
/// answer selects that word in place, with the system's selection handles and edit menu, and no
/// context-menu preview of the block.
///
/// The native rows (every row at standard text sizes). The SwiftUI rows (accessibility text sizes)
/// are SwiftUIHoldSelectsTextUITests.
final class ChatHoldSelectsWordUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testHoldOnAnswerSelectsTheWordNativeRows() {
        run(name: "native", arguments: [])
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
        // The newest answer's first paragraph.
        let paragraph = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "The transport switch holds up")).firstMatch
        let window = app.windows.firstMatch
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        func clear() -> Bool { paragraph.exists && paragraph.frame.minY > barBottom + 8 && paragraph.frame.maxY < window.frame.maxY - 140 }
        for _ in 0..<6 where !clear() {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: paragraph.exists ? 120 : 180)))
        }
        XCTAssertTrue(clear(), "the answer paragraph is fully on screen\n\(app.debugDescription)")
        let whole = paragraph.label

        // Hold on the first line's second word ("transport"), about 50 pt in from the text's
        // leading edge, half a line down.
        let frame = paragraph.frame
        let word = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 50, dy: frame.minY + 10))
        word.press(forDuration: 1.0)

        let selection = app.textViews["chat.textSelection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5),
                      "holding on answer text starts an in-place text selection\n\(app.debugDescription)")
        let selected = (selection.value as? String) ?? ""
        attach(app, "\(name)-hold-selects-word")
        XCTAssertFalse(selected.isEmpty, "a word is selected")
        XCTAssertFalse(selected.contains(" "), "one word is selected, not the block: \"\(selected)\"")
        XCTAssertTrue(whole.contains(selected), "the selected word is from the held paragraph: \"\(selected)\"")
        XCTAssertLessThan(selected.count, whole.count, "the selection is not the whole block")
        // The selection's own edit menu, not the block's context menu (whose Select Text opened a sheet).
        let copy = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == 'Copy' AND (elementType == %d OR elementType == %d)",
            XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue
        )).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the selection's edit menu offers Copy\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["Select Text"].exists, "no block context menu opened\n\(app.debugDescription)")

        // Hold, then drag right while held: some words, not the block.
        let again = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.minX + 10, dy: frame.minY + 10))
        again.press(forDuration: 1.0, thenDragTo: again.withOffset(CGVector(dx: 150, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(selection.waitForExistence(timeout: 5), "the selection is in place\n\(app.debugDescription)")
        let dragged = (selection.value as? String) ?? ""
        attach(app, "\(name)-hold-drag-selects-some")
        XCTAssertTrue(dragged.contains(" "), "a drag while held extends past one word: \"\(dragged)\"")
        XCTAssertTrue(whole.contains(dragged), "the words are from the held paragraph: \"\(dragged)\"")
        XCTAssertLessThan(dragged.count, whole.count, "the selection is not the whole block")
        XCTAssertFalse(app.buttons["Select Text"].exists, "still no block context menu")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

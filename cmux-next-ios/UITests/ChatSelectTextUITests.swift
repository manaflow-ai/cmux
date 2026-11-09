import XCTest

/// CMUX-33: answer text in the agent chat could not be range-selected, and a long press
/// grabbed the whole block. As in ChatGPT on iOS, a long press on an answer opens its context
/// menu; the menu's Select Text opens the text in a sheet where a range is selected and copied.
///
/// Both transcript paths: the native rows (standard text size) and the SwiftUI rows (every row
/// at accessibility sizes, where `.textSelection(.enabled)` took the press and the block's menu
/// had no Select Text).
final class ChatSelectTextUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLongPressOnAnswerOpensMenuWithSelectTextNativeRows() {
        run(name: "native", arguments: [])
    }

    @MainActor
    func testLongPressOnAnswerOpensMenuWithSelectTextSwiftUIRows() {
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
        // The history answer's first paragraph, scrolled into view (the chat opens at its newest row).
        let paragraph = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Every link frame")).firstMatch
        for _ in 0..<12 where !(paragraph.exists && paragraph.isHittable) {
            app.swipeDown()
        }
        XCTAssertTrue(paragraph.exists && paragraph.isHittable, "the answer paragraph is on screen\n\(app.debugDescription)")

        paragraph.press(forDuration: 1.2)
        let selectText = app.buttons["Select Text"].firstMatch
        XCTAssertTrue(selectText.waitForExistence(timeout: 5),
                      "a long press opens the answer's context menu with Select Text, not a whole-block selection\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Copy"].firstMatch.exists, "the menu offers Copy")
        attach(app, "\(name)-long-press-menu")
        selectText.tap()

        let text = app.textViews["selectText.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Select Text opens the text in a selectable view\n\(app.debugDescription)")
        XCTAssertTrue((text.value as? String ?? "").contains("Every link frame"), "the sheet holds the whole message")
        // A double tap selects one word: a range, with the system edit menu's Copy.
        // The first line's second word: 20 pt top inset, 16 pt leading inset.
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0)).withOffset(CGVector(dx: 0, dy: 32)).doubleTap()
        let copy = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == 'Copy' AND (elementType == %d OR elementType == %d)",
            XCUIElement.ElementType.menuItem.rawValue, XCUIElement.ElementType.button.rawValue
        )).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "a word is selected as a range with Copy\n\(app.debugDescription)")
        attach(app, "\(name)-range-selected")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

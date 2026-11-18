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
        // The newest answer's first paragraph, near the bottom where the chat opens. Small drags
        // only: scrolling up into the earlier turns' incoming agent-message cards crashes the
        // base app (a SwiftUI stack overflow in AgentSenderIcon while the list prefetches).
        let paragraph = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "The transport switch holds up")).firstMatch
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

        paragraph.press(forDuration: 1.2)
        let selectText = app.buttons["Select Text"].firstMatch
        XCTAssertTrue(selectText.waitForExistence(timeout: 5),
                      "a long press opens the answer's context menu with Select Text, not a whole-block selection\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Copy"].firstMatch.exists, "the menu offers Copy")
        attach(app, "\(name)-long-press-menu")
        selectText.tap()

        let text = app.textViews["selectText.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Select Text opens the text in a selectable view\n\(app.debugDescription)")
        XCTAssertTrue((text.value as? String ?? "").contains("The transport switch holds up"), "the sheet holds the whole message")
        // A double tap selects one word: a range, with the system edit menu's Copy. The text view
        // runs under the sheet's navigation bar, so the first line is placed from the bar's bottom
        // edge (20 pt top inset, 16 pt leading inset), after the sheet has stopped moving.
        let bar = app.navigationBars["Select text"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the sheet's bar shows\n\(app.debugDescription)")
        var lastBottom = -1.0
        for _ in 0..<20 where abs(bar.frame.maxY - lastBottom) > 0.5 {
            lastBottom = bar.frame.maxY
            _ = app.buttons["Done"].waitForExistence(timeout: 0.25)
        }
        // "transport", the first line's second word: about 50 pt in from the text's leading edge.
        let word = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: text.frame.minX + 16 + 50, dy: bar.frame.maxY + 20 + 11))
        word.doubleTap()
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

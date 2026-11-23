import XCTest

/// Leo, 2026-11-23: holding on a bubble should not lift the whole bubble; it should highlight text as
/// normal, then you adjust the selection. In Chief's transcript a hold on a text bubble selects the
/// word under the finger in place (handles and the edit menu), with no lifted bubble or tapback menu;
/// a double tap still opens the tapbacks.
final class ChiefHoldSelectsWordUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testHoldOnChiefBubbleSelectsTheWord() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "chief-open"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.textViews["conversation.composer.text"].waitForExistence(timeout: 30),
                      "Chief's conversation opens\n\(app.debugDescription)")
        // The mock Chief's "Claude finished the TabsKit integration. ..." message.
        let bubble = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "conversation.bubble.", "TabsKit integration"
        )).firstMatch
        let window = app.windows.firstMatch
        let barBottom = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : window.frame.minY + 100
        func clear() -> Bool { bubble.exists && bubble.frame.minY > barBottom + 8 && bubble.frame.maxY < window.frame.maxY - 160 }
        for _ in 0..<8 where !clear() {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 160)))
        }
        XCTAssertTrue(clear(), "Chief's text bubble is on screen\n\(app.debugDescription)")

        // Hold on the first word ("Claude"): inside the bubble's padding, on its first line.
        let frame = bubble.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.minX + 30, dy: frame.minY + 18))
            .press(forDuration: 1.0)

        let selection = app.textViews["chat.textSelection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5),
                      "holding on a bubble's text starts an in-place text selection\n\(app.debugDescription)")
        let selected = (selection.value as? String) ?? ""
        attach(app, "chief-hold-selects-word")
        XCTAssertFalse(selected.isEmpty, "a word is selected")
        XCTAssertFalse(selected.contains(" "), "one word is selected, not the bubble: \"\(selected)\"")
        XCTAssertTrue("Claude finished the TabsKit integration".contains(selected), "the word is from the held bubble: \"\(selected)\"")
        // The old hold lifted the bubble with its menu (Reply, Copy, Select, More…).
        XCTAssertFalse(app.buttons["Reply"].exists, "no lifted bubble menu\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["More…"].exists, "no lifted bubble menu")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

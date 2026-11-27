import XCTest

/// CMUX-34: as in Safari, a tap on the page (the agent chat transcript) while the
/// composer is being edited lowers the keyboard and keeps the draft. Real touches on
/// the shipping app's offline DEBUG chat (`kbd-chat`, mock sign-in).
final class TranscriptTapDismissUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTapOnTranscriptLowersKeyboardAndKeepsDraft() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "kbd-chat"]
        app.launch()
        defer { app.terminate() }

        let more = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30), "the pushed agent chat opens\n\(app.debugDescription)")
        attach(app, "1-rest")

        // The collapsed capsule opens the field.
        let field = app.textViews["chat.composer.field"]
        // The collapsed capsule is a button reading the placeholder.
        if !field.exists { app.buttons["Reply to Claude"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the composer field\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        expect(app.keyboards.firstMatch, "exists == true", "the keyboard comes up")
        field.typeText("keep this draft")
        attach(app, "2-typing")

        // A tap on the transcript, well above the composer.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        expect(app.keyboards.firstMatch, "exists == false", "a tap on the transcript lowers the keyboard")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the composer stays open with its draft")
        XCTAssertEqual(field.value as? String, "keep this draft", "the draft stays")
        attach(app, "3-after-tap")
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

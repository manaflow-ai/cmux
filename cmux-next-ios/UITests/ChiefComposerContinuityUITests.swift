import XCTest

/// The user, 2026-11-10: reopening a Chief conversation, the earlier composer
/// text "takes a second to come back instead of instant", and the keyboard
/// "weirdly unfocuses at random times like when I return from background".
/// Opens the mock Chief, types, goes back to Home and reopens it: the text is
/// in the field the moment the field exists. Then with the keyboard up, sends
/// the app to the background and brings it back: the field still has the
/// keyboard. Before, the text filled in after the push settled, and a
/// foreground return could leave the field without its keyboard.
final class ChiefComposerContinuityUITests: XCTestCase {
    private let draft = "Draft kept across visits"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheDraftIsBackAtOnceOnReopen() throws {
        let app = launch()
        let field = app.textViews["conversation.composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Chief's composer\n\(app.debugDescription)")
        field.tap()
        field.typeText(draft)
        attach(app, "1-typed")

        app.buttons["Back"].firstMatch.tap()
        let row = chiefRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Chief on Home\n\(app.debugDescription)")
        attach(app, "2-home")
        row.tap()

        // The first moment the reopened field exists, it already holds the text.
        let reopened = app.textViews["conversation.composer.text"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 10), "reopened composer\n\(app.debugDescription)")
        attach(app, "3-reopen-immediate")
        XCTAssertEqual(reopened.value as? String, draft, "the draft is in the field as the screen opens")
    }

    @MainActor
    func testTheKeyboardStaysAfterTheBackground() throws {
        let app = launch()
        let field = app.textViews["conversation.composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Chief's composer\n\(app.debugDescription)")
        field.tap()
        field.typeText("Hello")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard up")
        attach(app, "1-keyboard")

        for trip in 1...3 {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "in the background (trip \(trip))")
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "back in front (trip \(trip))")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                          "the keyboard is back after trip \(trip)\n\(app.debugDescription)")
            attach(app, "2-back-\(trip)")
            // Still typing into the same field: focus, not only a keyboard.
            app.keyboards.firstMatch.keys["a"].tap()
        }
        XCTAssertEqual(field.value as? String, "Helloaaa", "every return kept typing into the field")
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "chief-open"]
        app.launch()
        return app
    }

    /// The mock Chief's Home row (the Mac's Chief, or its own conversation row).
    @MainActor
    private func chiefRow(in app: XCUIApplication) -> XCUIElement {
        let mac = app.buttons["home.chief.mac"]
        if mac.waitForExistence(timeout: 5) { return mac }
        return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.row.conv_chief'")).firstMatch
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

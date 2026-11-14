import XCTest

/// TestFlight, Nov 5: the emailed sign-in code was `FWT88N`, but the code step
/// showed a number pad and dropped the letters, so the code could not be entered.
/// Typed for real into the code field (mock account, signed out, the sheet opened
/// on the code step by `-cmux-mobile-email`): the letters must stay. Five of the six
/// characters, so the step does not verify and the screenshot keeps them.
final class EmailCodeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testTheCodeFieldTakesLetters() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_CLEAR_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-email", "lucas@cmux.com", "-cmux-mobile-no-restore"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Check your email"].waitForExistence(timeout: 30), "code step\n\(app.debugDescription)")
        let field = app.textFields["Code"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "code field\n\(app.debugDescription)")
        // The field takes focus when the step appears; wait for its keyboard (none
        // shows when the simulator uses the Mac's hardware keyboard).
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        // A fresh simulator covers its first letter keyboard with the "slide to type" tip.
        let tip = app.buttons["Continue"].firstMatch
        if tip.waitForExistence(timeout: 2) { tip.tap() }
        attach(app, "01-code-step")
        if app.keyboards.firstMatch.exists {
            XCTAssertTrue(app.keyboards.keys["F"].exists, "the code keyboard has no letters\n\(app.keyboards.firstMatch.debugDescription)")
        }

        field.typeText("fwt88")
        attach(app, "02-typed-fwt88")
        // The field's value is the code the boxes show (letters kept, uppercased).
        XCTAssertEqual(field.value as? String, "FWT88")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

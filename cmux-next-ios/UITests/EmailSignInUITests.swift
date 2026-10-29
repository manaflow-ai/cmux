import XCTest

final class EmailSignInUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEmailIsFocusedOnPresentationAndReopening() {
        let app = launchEmailSheet()
        assertEmailAcceptsTyping(app, text: "first@example.com")

        app.buttons["Close"].tap()
        let emailButton = app.buttons["Continue with email"]
        XCTAssertTrue(emailButton.waitForExistence(timeout: 5))
        emailButton.tap()
        assertEmailAcceptsTyping(app, text: "second@example.com")
    }

    @MainActor
    func testReturningFromCodeFocusesEmail() {
        let app = launchEmailSheet()
        assertEmailAcceptsTyping(app, text: "first@example.com")
        app.buttons["Continue"].tap()

        let differentEmail = app.buttons["Use a different email"]
        XCTAssertTrue(differentEmail.waitForExistence(timeout: 5))
        differentEmail.tap()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Typing through the app, without tapping the field, proves focus moved back.
        app.typeText("x")
        XCTAssertEqual(email.value as? String, "first@example.comx")
    }

    @MainActor
    private func launchEmailSheet() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_CLEAR_AUTH"] = "1"
        app.launchArguments = ["-cmux-mobile-email", "", "-cmux-mobile-no-restore"]
        app.launch()
        return app
    }

    @MainActor
    private func assertEmailAcceptsTyping(_ app: XCUIApplication, text: String) {
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText(text)
        XCTAssertEqual(email.value as? String, text)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "email-focused"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

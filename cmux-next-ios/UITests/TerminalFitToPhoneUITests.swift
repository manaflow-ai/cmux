import XCTest

final class TerminalFitToPhoneUITests: XCTestCase {
    @MainActor
    func testOneTapWithKeyboardDownAndUpAndChoiceSurvivesRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments = ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-fit",
                               "-cmux-mobile-reset-fit"]
        app.launch()
        defer { app.terminate() }
        let fit = app.buttons["terminal.fitToPhone"]
        XCTAssertTrue(fit.waitForExistence(timeout: 30))
        XCTAssertFalse(fit.isSelected)
        XCTAssertTrue(fit.isHittable)
        XCTAssertGreaterThanOrEqual(fit.frame.width, 44)
        XCTAssertGreaterThanOrEqual(fit.frame.height, 44)
        capture("projection-keyboard-down")

        fit.tap()
        expectSelected(fit, true)
        capture("fit-keyboard-down")
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(fit.isHittable)
        fit.tap()
        expectSelected(fit, false)
        capture("projection-keyboard-up")
        fit.tap()
        expectSelected(fit, true)

        app.terminate()
        app.launchArguments.removeAll { $0 == "-cmux-mobile-reset-fit" }
        app.launch()
        XCTAssertTrue(fit.waitForExistence(timeout: 30))
        expectSelected(fit, true)
        capture("fit-after-relaunch")
    }

    @MainActor private func expectSelected(_ button: XCUIElement, _ selected: Bool) {
        let predicate = NSPredicate(format: "selected == %@", NSNumber(value: selected))
        let wait = XCTNSPredicateExpectation(predicate: predicate, object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 10), .completed)
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

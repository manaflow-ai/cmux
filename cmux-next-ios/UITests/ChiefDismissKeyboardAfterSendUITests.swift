import XCTest

/// Settings > Chat > "Dismiss keyboard after sending" holds for Chief too. The iOS release bar
/// read-back (2026-11-22, shot 17) sent a Chief message with it on and the keyboard stayed up:
/// only the agent chat read the setting. With it off, the keyboard stays for the next message.
final class ChiefDismissKeyboardAfterSendUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testChiefSendClosesTheKeyboardWhenSet() {
        let app = send(dismissing: true)
        defer { app.terminate() }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.keyboards)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "the keyboard closes after the send\n\(app.debugDescription)")
        attach(app, "after-send-dismissed")
    }

    @MainActor
    func testChiefSendKeepsTheKeyboardWhenOff() {
        let app = send(dismissing: false)
        defer { app.terminate() }
        // Gives a wrong dismissal its moment; the wait only paces the check.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "pace")], timeout: 1.5)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stays for the next message\n\(app.debugDescription)")
        attach(app, "after-send-kept")
    }

    @MainActor
    private func send(dismissing: Bool) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += [
            "-cmuxMobile.setupComplete", "YES",
            "-cmuxMobile.settings.dismissKeyboardAfterSend", dismissing ? "YES" : "NO",
            "-cmux-mobile-demo", "chief-open",
        ]
        app.launch()
        let field = app.textViews["conversation.composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Chief's composer\n\(app.debugDescription)")
        if !app.keyboards.firstMatch.exists { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard opens")
        field.typeText("status of the ios build?")
        let sendButton = app.buttons["conversation.composer.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "the send button shows with text")
        attach(app, "before-send")
        sendButton.tap()
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

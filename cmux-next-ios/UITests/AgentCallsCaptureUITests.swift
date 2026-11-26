import XCTest

/// Phone Calls (verify/agent-alarms.md "Phone calls"), every state of Settings → Notifications →
/// Phone Calls, as screenshots in light and dark: the service without a phone provider, loading,
/// a load that failed, no number yet, a number without its country code, the code call on its way,
/// a wrong code, the number confirmed, a trigger off, a test call, a second test call held by the
/// 30 second window, the Recent list with every outcome, and removing the number. The page talks
/// to `AgentCallMockService` (DEBUG mock mode): nothing is called and no account is needed.
final class AgentCallsCaptureUITests: XCTestCase {
    var app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testAgentCallsEveryState() throws {
        XCUIDevice.shared.orientation = .portrait
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            let mode = appearance == .dark ? "dark" : "light"
            capturePermutations(mode)
        }
    }

    @MainActor
    private func capturePermutations(_ mode: String) {
        // 1. Notifications shows Phone Calls under Agent Alarms.
        launch(scenario: "fresh", page: "notifications")
        let row = app.buttons["settings.notifications.agentCalls"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Notifications shows the Phone Calls row")
        shot("\(mode)-01-notifications-rows")

        // 2. No number yet.
        row.tap()
        let field = app.textFields["settings.agentCalls.numberField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Phone Calls asks for a number")
        XCTAssertEqual(app.switches["settings.agentCalls.enabled"].firstMatch.isEnabled, false, "the toggle waits for a number")
        shot("\(mode)-02-no-number")

        // 3. A number without its country code is refused.
        field.tap()
        field.typeText("4155550100")
        app.buttons["settings.agentCalls.verify"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.agentCalls.problem"].waitForExistence(timeout: 5))
        shot("\(mode)-03-number-needs-country-code")

        // 4. The code call goes out.
        field.tap()
        field.clearAndType("+1 415 555 0100")
        app.buttons["settings.agentCalls.verify"].firstMatch.tap()
        let code = app.textFields["settings.agentCalls.code"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 5), "the page asks for the code")
        shot("\(mode)-04-code-call-pending")

        // 5. A wrong code.
        code.tap()
        code.typeText("000000")
        app.buttons["settings.agentCalls.confirm"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.agentCalls.problem"].waitForExistence(timeout: 5))
        shot("\(mode)-05-wrong-code")

        // 6. The right code: the number is saved and calls are on.
        code.tap()
        code.clearAndType("123456")
        app.buttons["settings.agentCalls.confirm"].firstMatch.tap()
        let number = app.descendants(matching: .any)["settings.agentCalls.number"].firstMatch
        XCTAssertTrue(number.waitForExistence(timeout: 5), "the confirmed number shows")
        XCTAssertEqual(app.switches["settings.agentCalls.enabled"].firstMatch.value as? String, "1")
        shot("\(mode)-06-verified-on")

        // 7. One trigger off.
        let question = app.switches["settings.agentCalls.trigger.question"].firstMatch
        if question.waitForExistence(timeout: 5) { flip(question) }
        sleep(1)
        XCTAssertEqual(question.value as? String, "0")
        shot("\(mode)-07-question-trigger-off")

        // 8. A test call, then a second one inside 30 s is held.
        let test = app.buttons["settings.agentCalls.test"].firstMatch
        scrollTo(test)
        test.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.agentCalls.notice"].waitForExistence(timeout: 5))
        sleep(2)
        shot("\(mode)-08-test-call-placed")
        scrollTo(test)
        test.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.agentCalls.problem"].waitForExistence(timeout: 5))
        scrollTo(app.descendants(matching: .any)["settings.agentCalls.debounce"].firstMatch)
        shot("\(mode)-09-test-call-debounced")
        app.swipeUp()
        app.swipeUp()
        shot("\(mode)-10-recent-after-test")

        // 9. Removing the number turns calls off.
        app.swipeDown()
        app.swipeDown()
        app.swipeDown()
        let remove = app.buttons["settings.agentCalls.removeNumber"].firstMatch
        if remove.waitForExistence(timeout: 5) { remove.tap() }
        XCTAssertTrue(app.textFields["settings.agentCalls.numberField"].firstMatch.waitForExistence(timeout: 5))
        shot("\(mode)-11-number-removed")

        // 10. Recent with every outcome: called (per trigger and test), held, refused by the provider.
        launch(scenario: "history", page: "agentCalls")
        XCTAssertTrue(app.descendants(matching: .any)["settings.agentCalls.number"].firstMatch.waitForExistence(timeout: 30))
        shot("\(mode)-12-history-top")
        app.swipeUp()
        shot("\(mode)-13-history-sample-and-countdown")
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["settings.agentCalls.recent.debounced"].exists, "Recent shows a held call")
        XCTAssertTrue(app.descendants(matching: .any)["settings.agentCalls.recent.failed"].exists, "Recent shows a refused call")
        shot("\(mode)-14-history-recent")

        // 11. The service has no phone provider yet.
        launch(scenario: "unconfigured", page: "agentCalls")
        XCTAssertTrue(app.switches["settings.agentCalls.enabled"].firstMatch.waitForExistence(timeout: 30))
        shot("\(mode)-15-not-configured")

        // 12. Loading, and a load that failed.
        launch(scenario: "loading", page: "agentCalls")
        XCTAssertTrue(app.descendants(matching: .any)["settings.agentCalls.loading"].firstMatch.waitForExistence(timeout: 30))
        shot("\(mode)-16-loading")
        launch(scenario: "unreachable", page: "agentCalls")
        XCTAssertTrue(app.buttons["settings.agentCalls.retry"].firstMatch.waitForExistence(timeout: 30))
        shot("\(mode)-17-load-failed")

        // 13. A code call already pending when the page opens.
        launch(scenario: "pending", page: "agentCalls")
        XCTAssertTrue(app.textFields["settings.agentCalls.code"].firstMatch.waitForExistence(timeout: 30))
        shot("\(mode)-18-pending-on-open")
    }

    @MainActor
    private func launch(scenario: String, page: String) {
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_DEV_AGENT_CALL"] = scenario
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "settings", "-cmux-mobile-settings-page", page]
        app.launch()
        let allow = springboard.alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement) {
        var tries = 0
        while !(element.exists && element.isHittable), tries < 4 {
            app.swipeUp()
            tries += 1
        }
    }

    @MainActor
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        let current = (value as? String) ?? ""
        tap()
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2) + text)
    }
}

import XCTest

/// Agent Alarms when the person says no to iOS's alarm prompt (verify/agent-alarms.md): the
/// switch stays off, permission reads Off with a way to iOS Settings, and a push that would
/// ring rings nothing. Run on its own simulator: iOS asks only once per install, and
/// `AgentAlarmsCaptureUITests` allows.
final class AgentAlarmsDeniedCaptureUITests: XCTestCase {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    @MainActor
    func testAgentAlarmsDenied() throws {
        XCUIDevice.shared.orientation = .portrait
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            let name = appearance == .dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "settings",
                                    "-cmux-mobile-settings-page", "agentAlarms"]
            app.launch()
            let enabled = app.switches["settings.agentAlarms.enabled"].firstMatch
            XCTAssertTrue(enabled.waitForExistence(timeout: 30))
            enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
            let deny = springboard.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Don")).firstMatch
            if deny.waitForExistence(timeout: 10) {
                shot("01-permission-prompt-\(name)")
                deny.tap()
            }
            XCTAssertTrue(app.staticTexts["Off"].waitForExistence(timeout: 10), "permission reads Off")
            XCTAssertEqual(enabled.value as? String, "0", "the switch stays off")
            shot("02-denied-\(name)")
            app.swipeUp()
            shot("03-denied-triggers-dimmed-\(name)")
            app.terminate()
        }
        XCUIDevice.shared.appearance = .light
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

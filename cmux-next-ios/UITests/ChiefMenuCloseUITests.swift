import XCTest

/// The Chief header's ••• button stays a glass circle while its menu closes (it flashed as a
/// square right after the menu went away). Opens and closes the menu a few times in dark and in
/// light, holding each step so `video` (cmux-next-ios-sim.sh) records the close transition.
final class ChiefMenuCloseUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testMenuCloseKeepsTheButtonCircular() {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            let name = appearance == .dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmuxMobile.settings.appearance", name,
                                    "-cmux-mobile-demo", "chief-open"]
            app.launch()

            let button = app.buttons["conversation.header.trailing"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 30), "the Chief conversation opens\n\(app.debugDescription)")
            hold(2)
            attach(app, "chief-menu-\(name)-rest")
            for round in 1...3 {
                button.tap()
                let item = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chat Colors")).firstMatch
                XCTAssertTrue(item.waitForExistence(timeout: 10), "the ••• menu opens\n\(app.debugDescription)")
                hold(1)
                if round == 1 { attach(app, "chief-menu-\(name)-open") }
                // Close by tapping the transcript, away from the menu.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6)).tap()
                XCTAssertTrue(item.waitForNonExistence(timeout: 10), "the ••• menu closes")
                hold(1.5)
            }
            attach(app, "chief-menu-\(name)-closed")
            XCTAssertTrue(button.isHittable, "the button is back in the header")
            app.terminate()
        }
    }

    /// A bounded hold so the recording shows each step (not synchronization).
    private func hold(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "hold for the recording")], timeout: seconds)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

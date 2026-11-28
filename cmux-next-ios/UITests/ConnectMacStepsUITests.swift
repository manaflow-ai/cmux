import XCTest

final class ConnectMacStepsUITests: XCTestCase {
    @MainActor
    func testUnregisteredMacExplainsHowToEnableConnectionsBehindTheInfoCircle() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore",
                                "-cmux-mobile-demo", "connect-mac-no-account"]
        app.launch()
        defer { app.terminate() }

        let account = app.buttons["connect-mac.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 30), "The account has no registered Macs.")
        let help = app.buttons["connect-mac.help"]
        XCTAssertTrue(help.waitForExistence(timeout: 5), "The steps sit behind an info circle, not on the screen.")
        help.tap()
        let setting = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Allow iPhone Connections")).firstMatch
        XCTAssertTrue(setting.waitForExistence(timeout: 5), "An unregistered Mac may have connections disabled.")
        XCTAssertTrue(setting.isHittable, "The connection setting shows in the info popover.")
        let signIn = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Sign in to cmux on your Mac")).firstMatch
        XCTAssertTrue(signIn.exists)
        XCTAssertTrue(app.descendants(matching: .any)["connect-mac.status"].exists)
        XCTAssertTrue(account.isHittable, "Keep the Account Settings action available.")
        // The link and status center under the centered title, not in a leading column (read-back 2026-11-28).
        let screenMidX = app.windows.firstMatch.frame.midX
        XCTAssertEqual(account.frame.midX, screenMidX, accuracy: 12, "Account Settings centers under Connect your Mac.")
        let status = app.descendants(matching: .any)["connect-mac.status"]
        let row = status.frame.union(help.frame)
        XCTAssertEqual(row.midX, screenMidX, accuracy: 12, "The status line centers under Connect your Mac.")
    }
}

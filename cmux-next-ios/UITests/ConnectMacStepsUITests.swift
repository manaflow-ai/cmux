import XCTest

final class ConnectMacStepsUITests: XCTestCase {
    @MainActor
    func testUnregisteredMacStillExplainsHowToEnableConnections() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore",
                                "-cmux-mobile-demo", "connect-mac-no-account"]
        app.launch()
        defer { app.terminate() }

        let account = app.buttons["connect-mac.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 30), "The account has no registered Macs.")
        let setting = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Allow iPhone Connections")).firstMatch
        XCTAssertTrue(setting.waitForExistence(timeout: 5), "An unregistered Mac may have connections disabled.")
        XCTAssertTrue(setting.isHittable, "The connection setting must be visible on the setup screen.")
        let signIn = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Sign in to cmux on your Mac")).firstMatch
        XCTAssertTrue(signIn.exists)
        XCTAssertTrue(app.descendants(matching: .any)["connect-mac.status"].exists)
        XCTAssertTrue(account.isHittable, "Keep the Account Settings action available.")
    }
}

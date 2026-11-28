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
        // App Review 2.1(a): with no Mac there is still something to try (iOS release bar read-back 2026-11-28).
        app.tap() // dismiss the popover
        let cloudChief = app.buttons["workspaces.connect-mac.cloud-chief"]
        XCTAssertTrue(cloudChief.waitForExistence(timeout: 5), "No Mac: the empty state offers the Cloud Chief.")
        XCTAssertTrue(cloudChief.isHittable)
        cloudChief.tap()
        XCTAssertTrue(app.tabBars.buttons.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertFalse(cloudChief.exists, "Chat with Chief leaves Workspaces for Home's Cloud Chief.")
    }
}

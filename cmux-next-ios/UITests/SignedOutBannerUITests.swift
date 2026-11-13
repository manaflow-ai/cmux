import XCTest

/// The signed-out banner in place over Workspaces, and its one button: Sign in signs
/// out (keeping the phone's keys) and opens sign-in. Drives the DEBUG
/// `-cmux-mobile-banner-demo signed-out` state on mock data; run with `video` to see it.
final class SignedOutBannerUITests: XCTestCase {
    @MainActor
    func testSignedOutBannerSignInOpensSignIn() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore",
                                "-cmux-mobile-tab", "workspaces", "-cmux-mobile-banner-demo", "signed-out"]
        app.launch()
        defer { app.terminate() }

        let text = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "This device was signed out")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 30), "The signed-out banner shows over Workspaces.")
        let signIn = app.buttons["connection.action"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5), "The banner offers Sign in.")
        XCTAssertEqual(signIn.label, "Sign in")
        // Hold on the banner so a recording shows it at rest.
        _ = app.buttons["never.there"].waitForExistence(timeout: 2)
        signIn.tap()

        XCTAssertTrue(app.buttons["Continue with email"].waitForExistence(timeout: 20),
                      "Sign in signs out and opens sign-in.")
        _ = app.buttons["never.there"].waitForExistence(timeout: 2)
    }
}

import XCTest

/// Delete Account with an App Store subscription (Guideline 5.1.1(v)):
/// deleting a cmux account does not cancel the subscription, so when one is
/// set to renew Settings > Account warns in a native alert with Manage
/// Subscription, Delete Account and Cancel. Without one, the plain
/// confirmation stays. Runs on the DEBUG mock account; the subscription state
/// comes from `CMUX_MOBILE_ACCOUNT_DELETION_DEMO` (`AccountDeletionCheck.demo`).
/// Never confirms a deletion. Each state is captured in light and dark.
final class AccountDeletionAppStoreUITests: XCTestCase {
    private static let warningTitle = "Your App Store subscription will keep renewing"
    private static let confirmationTitle = "Delete your cmux account?"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    @MainActor
    func testRenewingAppStoreSubscriptionWarnsBeforeDeleting() throws {
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            let app = openDeleteAccount(demo: "app-store-renewing", appearance: appearance)
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 10), "a renewing App Store subscription must warn; on screen: \(app.debugDescription.prefix(800))")
            XCTAssertTrue(alert.staticTexts[Self.warningTitle].exists)
            XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Apple keeps charging you until you cancel it in the App Store")).firstMatch.exists)
            XCTAssertTrue(alert.buttons["Manage Subscription"].exists)
            XCTAssertTrue(alert.buttons["Delete Account"].exists)
            XCTAssertTrue(alert.buttons["Cancel"].exists)
            XCTAssertFalse(app.staticTexts[Self.confirmationTitle].exists, "the warning stands in for the plain confirmation")
            capture("renewing-alert", appearance)
            alert.buttons["Cancel"].tap()
            XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "Cancel must close the warning")
            XCTAssertTrue(app.buttons["settings.deleteAccount"].exists, "Cancel must leave the account in place")
            app.terminate()
        }
    }

    @MainActor
    func testWithoutAnAppStoreSubscriptionTheConfirmationStays() throws {
        for (demo, name) in [("none", "no-subscription"), ("unavailable", "check-unavailable")] {
            for appearance in [XCUIDevice.Appearance.light, .dark] {
                XCUIDevice.shared.appearance = appearance
                let app = openDeleteAccount(demo: demo, appearance: appearance)
                let ask = app.staticTexts[Self.confirmationTitle]
                XCTAssertTrue(ask.waitForExistence(timeout: 10), "\(demo): Delete Account must ask with the plain confirmation")
                XCTAssertFalse(app.staticTexts[Self.warningTitle].exists, "\(demo): no App Store warning")
                capture("\(name)-confirmation", appearance)
                app.alerts.firstMatch.buttons["Cancel"].tap()
                XCTAssertTrue(ask.waitForNonExistence(timeout: 5))
                app.terminate()
            }
        }
    }

    /// Manage Subscription hands off to Apple's subscription management
    /// (StoreKit's sheet, or Apple's page) and leaves the account in place.
    @MainActor
    func testManageSubscriptionOpensApplesSubscriptionManagement() throws {
        XCUIDevice.shared.appearance = .light
        let app = openDeleteAccount(demo: "app-store-renewing")
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["Manage Subscription"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "Manage Subscription must close the warning")
        // StoreKit's own sheet over the app (on a simulator without an App
        // Store account it says Cannot Connect, then asks to sign in), or
        // Safari with Apple's subscriptions page (the fallback).
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let storeKitSheet = app.otherElements.containing(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Cannot Connect", "Apple Account")).firstMatch
        let handedOff = storeKitSheet.waitForExistence(timeout: 10)
            || app.staticTexts["Cannot Connect"].exists
            || app.staticTexts["Apple Account Sign in Requested"].exists
            || safari.state == .runningForeground
            // A full-screen system sheet over the page: Delete Account is covered.
            || !app.buttons["settings.deleteAccount"].isHittable
        capture("manage-subscription", .light)
        XCTAssertTrue(handedOff, "Manage Subscription must open Apple's subscription management; on screen: \(app.debugDescription.prefix(800))")
        if safari.state != .notRunning { safari.terminate() }
        app.activate()
        XCTAssertTrue(app.buttons["settings.deleteAccount"].waitForExistence(timeout: 10), "managing the subscription must leave the account in place")
        app.terminate()
    }

    // MARK: - Helpers

    @MainActor
    private func openDeleteAccount(demo: String, appearance: XCUIDevice.Appearance = .light) -> XCUIApplication {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        if safari.state != .notRunning { safari.terminate() }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-cmux-mobile-no-restore",
                                "-cmuxMobile.setupComplete", "YES",
                                "-cmux-mobile-tab", "settings", "-cmux-mobile-settings-page", "account",
                                // The app's own Appearance setting (Settings > Appearance) wins
                                // over the device's, so each capture sets it.
                                "-cmuxMobile.settings.appearance", appearance == .dark ? "dark" : "light"]
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_ACCOUNT_DELETION_DEMO"] = demo
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 3), app.buttons["Manaflow"].exists { app.buttons["Manaflow"].tap() }
        let delete = app.buttons["settings.deleteAccount"]
        XCTAssertTrue(delete.waitForExistence(timeout: 30), "Settings > Account must show Delete Account")
        for _ in 0..<8 where !delete.isHittable { app.windows.firstMatch.swipeUp(velocity: .slow) }
        delete.tap()
        return app
    }

    @MainActor
    private func capture(_ name: String, _ appearance: XCUIDevice.Appearance) {
        let environment = ProcessInfo.processInfo.environment
        let device = (environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "").hasPrefix("iPad") ? "ipad" : "iphone"
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "account-delete-\(device)-\(appearance == .dark ? "dark" : "light")-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

import XCTest

/// Settings → Cloud → Cloud Machines (CMUX-487), drawn by the production screen with the
/// gallery's fixed machines (`-cmux-mobile-recovery-gallery cloudmachines`): the list, one
/// machine's page and New Cloud Machine, in light and dark.
final class CloudMachinesCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCloudMachinesPageLight() throws { try walk(.light, "light") }

    @MainActor
    func testCloudMachinesPageDark() throws { try walk(.dark, "dark") }

    @MainActor
    private func walk(_ appearance: XCUIDevice.Appearance, _ name: String) throws {
        XCUIDevice.shared.appearance = appearance
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-recovery-gallery", "cloudmachines", "-cmux-mobile-no-restore",
                                "-cmux-mobile-gallery-appearance", name]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.navigationBars["Cloud Machines"].waitForExistence(timeout: 30), "page\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Build box"].waitForExistence(timeout: 10), "rows\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Nightly evals"].exists)
        shot(app, "\(name)-01-list")

        app.staticTexts["Build box"].tap()
        XCTAssertTrue(app.navigationBars["Build box"].waitForExistence(timeout: 10), "detail\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["cloudMachines.pause"].exists, "Pause on a running machine")
        shot(app, "\(name)-02-machine")
        app.swipeUp()
        XCTAssertTrue(app.buttons["cloudMachines.delete"].waitForExistence(timeout: 5))
        shot(app, "\(name)-03-machine-more")

        app.navigationBars["Build box"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Cloud Machines"].waitForExistence(timeout: 10))
        app.buttons["cloudMachines.new"].tap()
        XCTAssertTrue(app.navigationBars["New Cloud Machine"].waitForExistence(timeout: 10), "sheet\n\(app.debugDescription)")
        shot(app, "\(name)-04-new")
    }
}

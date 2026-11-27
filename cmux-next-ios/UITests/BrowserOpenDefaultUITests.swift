import XCTest

/// Settings → Browser → Open New Pages, walked on video (`cmux-next-ios-sim.sh test ui=BrowserOpenDefaultUITests video`):
/// the person picks each choice, then each kind of page opens on the iPhone or streams from the Mac.
final class BrowserOpenDefaultUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    /// Settings: the root row, the page, and a tap on each choice (the checkmark and the explanation move).
    @MainActor
    func testPickingEachChoiceInSettings() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "settings", "-cmux-mobile-no-restore",
                                "-cmuxMobile.settings.browserOpenDefault", "automatic"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["settings.browser.row"]
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Browser row\n\(app.debugDescription)")
        pause(1)
        attach(app, "settings-root-browser-row")
        row.tap()
        XCTAssertTrue(app.navigationBars["Browser"].waitForExistence(timeout: 10))
        pause(1.5)
        attach(app, "browser-page-automatic")
        for choice in ["phone", "stream", "automatic"] {
            let button = app.buttons["settings.browser.openDefault.\(choice)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), choice)
            button.tap()
            pause(1.5)
            XCTAssertTrue(button.isSelected, "\(choice) checked")
            attach(app, "browser-page-\(choice)-picked")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        pause(1)
        attach(app, "settings-root-after")
    }

    /// Each page kind under each choice, through the real rule and the production tab page.
    @MainActor
    func testEachPageKindUnderEachChoice() {
        for choice in ["automatic", "phone", "stream"] {
            for kind in ["public", "html", "signin", "localhost", "private", "blank", "macfile", "unreadable"] {
                let app = XCUIApplication()
                app.launchArguments += ["-cmux-mobile-browser-placement", kind, "-cmuxMobile.settings.browserOpenDefault", choice]
                app.launch()
                XCTAssertTrue(app.otherElements["browser.placement.caption"].waitForExistence(timeout: 15)
                              || app.staticTexts.firstMatch.waitForExistence(timeout: 5), "\(choice) \(kind)")
                pause(3)
                attach(app, "\(choice)-\(kind)")
                app.terminate()
            }
        }
    }

    @MainActor private func pause(_ seconds: TimeInterval) {
        let wait = XCTestExpectation(description: "settle")
        wait.isInverted = true
        _ = XCTWaiter.wait(for: [wait], timeout: seconds)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

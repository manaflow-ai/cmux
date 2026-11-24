import XCTest

/// Site monograms on tab cards (taste prototype, Settings → Advanced, off by default): with the
/// setting on, a browser card with no picture yet shows its site's letter instead of the globe.
/// Mock data: workspace `ws-cmux`'s Swift docs tab (developer.apple.com) has no picture. Run with
/// `cmux-next-ios-sim.sh test ui=TabCardMonogramUITests video` for the PR's clip.
final class TabCardMonogramUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testGridShowsSiteMonogramWhenOn() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                "-cmuxMobile.settings.tabCardMonograms", "YES"]
        app.launch()

        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        row.tap()

        let tabsButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 15), "tabs button\n\(app.debugDescription)")
        tabsButton.tap()

        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Swift docs' AND label ENDSWITH ', tab'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the browser card\n\(app.debugDescription)")
        // Hold on the grid so the clip shows it.
        Thread.sleep(forTimeInterval: 3)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "grid-monogram"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

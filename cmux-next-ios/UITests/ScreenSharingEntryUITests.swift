import XCTest

/// + › Screen Sharing in a workspace (user report 2026-11-03: "how can i create a mac screen
/// sharing tab in ios? … i dont see screen sharing"). Mock data: the workspace's + menu lists
/// Screen Sharing, and choosing it opens the account's Macs as a sheet that Done closes.
final class ScreenSharingEntryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPlusMenuOpensScreenSharing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()

        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        row.tap()

        let tabsButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 15), "tabs button\n\(app.debugDescription)")
        tabsButton.tap()
        settle(1)
        attach(app, "01-tab-grid")

        let plus = app.buttons["New"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 15), "+ menu\n\(app.debugDescription)")
        plus.tap()
        let entry = app.buttons["Screen Sharing"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Screen Sharing in +\n\(app.debugDescription)")
        settle(0.6)
        attach(app, "02-plus-menu")
        entry.tap()

        let page = app.descendants(matching: .any)["screenSharing.page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15), "Screen Sharing sheet\n\(app.debugDescription)")
        XCTAssertTrue(app.navigationBars["Screen Sharing"].exists || app.staticTexts["Screen Sharing"].exists)
        settle(2)
        attach(app, "03-screen-sharing-sheet")

        app.buttons["screenSharing.done"].firstMatch.tap()
        XCTAssertTrue(page.waitForNonExistence(timeout: 10), "Done closes the sheet")
        settle(0.6)
        attach(app, "04-back-in-workspace")
    }

    /// Lets an animation finish before a screenshot (a run loop wait, not app synchronization).
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

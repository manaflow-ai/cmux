import XCTest

/// CMUX-489, reworked 2026-11-13: Home says its Mac's list is not live the way the Workspaces
/// tab does. Kept rows stay (dimmed) under the navigation subtitle "Offline · last known" or
/// "Couldn't refresh · last known", with no card over the list; with nothing kept, Workspaces'
/// empty state for that Mac shows ("Can't connect to …" with Retry, or "… is offline").
final class HomeMacDisconnectedUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ demo: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-demo", demo]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons.element(boundBy: 0).tap() }
        return app
    }

    @MainActor
    func testAnOfflineMacMarksTheKeptRowsInTheSubtitle() throws {
        let app = launch("retry-home-offline")
        let row = app.buttons["home.row.stress-5"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "a kept Home row\n\(app.debugDescription)")
        let subtitle = app.navigationBars.staticTexts["Offline · last known"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10), "Workspaces' subtitle\n\(app.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["home.note.problem"].exists, "no card over the kept rows")
        attach(app, "1-home-offline-kept-rows")

        // Non-blocking: the kept rows still open.
        row.tap()
        XCTAssertTrue(app.buttons["home.compose"].waitForNonExistence(timeout: 10), "a kept row opens\n\(app.debugDescription)")
        attach(app, "2-row-opened")
    }

    @MainActor
    func testAFailedReadMarksTheKeptRowsInTheSubtitle() throws {
        let app = launch("retry-home-failed")
        XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "a kept Home row\n\(app.debugDescription)")
        XCTAssertTrue(app.navigationBars.staticTexts["Couldn't refresh · last known"].waitForExistence(timeout: 10),
                      "Workspaces' subtitle\n\(app.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["home.note.problem"].exists, "no card over the kept rows")
        attach(app, "3-home-failed-kept-rows")
    }

    @MainActor
    func testNothingKeptShowsWorkspacesEmptyStateWithRetry() throws {
        let app = launch("retry-home-unreachable-empty")
        let title = app.staticTexts["Can't connect to Demo Mac 1"]
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Workspaces' empty state\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Retry"].exists, "Retry\n\(app.debugDescription)")
        attach(app, "4-home-unreachable-empty")
    }

    @MainActor
    func testNothingKeptFromAnAsleepMacSaysItIsOffline() throws {
        let app = launch("retry-home-asleep-empty")
        XCTAssertTrue(app.staticTexts["Demo Mac 1 is offline"].waitForExistence(timeout: 30), "Workspaces' empty state\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["Retry"].exists, "nothing to dial")
        attach(app, "5-home-asleep-empty")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

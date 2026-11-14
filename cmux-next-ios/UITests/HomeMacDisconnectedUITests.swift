import XCTest

/// CMUX-489, reworked 2026-11-13: Home says its Mac's list is not live the way the Workspaces
/// tab does, without covering anything: kept rows show exactly as normal, and the toolbar's Mac
/// button carries the status ("<Mac> · Offline · last known" or "· Couldn't refresh · last known"
/// and Retry in its menu); with nothing kept, Workspaces' empty state for that Mac shows
/// ("Can't connect to …" with Retry, or "… is offline"). A kept row opens the conversation
/// under its own "Not connected" bar, never a full-screen error.
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
    func testAnOfflineMacMarksTheKeptRowsInTheMacMenu() throws {
        let app = launch("retry-home-offline")
        let row = app.buttons["home.row.stress-5"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "a kept Home row\n\(app.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["home.note.problem"].exists, "no card over the kept rows")
        attach(app, "1-home-offline-kept-rows")
        try openMacMenu(app, saying: "Offline · last known")
        attach(app, "1b-home-offline-mac-menu")
        app.buttons["home.mac.retry"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the rows stay after Retry")

        // Non-blocking: the kept rows still open.
        row.tap()
        XCTAssertTrue(app.buttons["home.compose"].waitForNonExistence(timeout: 10), "a kept row opens\n\(app.debugDescription)")
        // The conversation itself opens, under its "Not connected" bar, never a full-screen error.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Not connected to your Mac")).firstMatch
                        .waitForExistence(timeout: 20),
                      "the conversation's own bar\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["home.conversation.retry"].exists, "no full-screen error")
        XCTAssertTrue(app.textViews.firstMatch.exists || app.textFields.firstMatch.exists, "the composer shows\n\(app.debugDescription)")
        attach(app, "2-row-opened-conversation")
    }

    @MainActor
    func testAFailedReadMarksTheKeptRowsInTheMacMenu() throws {
        let app = launch("retry-home-failed")
        XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "a kept Home row\n\(app.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["home.note.problem"].exists, "no card over the kept rows")
        attach(app, "3-home-failed-kept-rows")
        try openMacMenu(app, saying: "Couldn't refresh · last known")
        attach(app, "3b-home-failed-mac-menu")
    }

    @MainActor
    func testNothingKeptShowsWorkspacesEmptyStateWithRetry() throws {
        let app = launch("retry-home-unreachable-empty")
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Can't connect to Demo Mac 1")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Workspaces' empty state\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Retry"].exists, "Retry\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["No Conversations"].exists, "one empty state, not two")
        attach(app, "4-home-unreachable-empty")
    }

    @MainActor
    func testNothingKeptFromAnAsleepMacSaysItIsOffline() throws {
        let app = launch("retry-home-asleep-empty")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Demo Mac 1", "is offline")).firstMatch.waitForExistence(timeout: 30), "Workspaces' empty state\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["Retry"].exists, "nothing to dial")
        XCTAssertFalse(app.staticTexts["No Conversations"].exists, "one empty state, not two")
        attach(app, "5-home-asleep-empty")
    }

    /// The Mac button carries the status: its value names it, its menu says it with Retry.
    @MainActor
    private func openMacMenu(_ app: XCUIApplication, saying detail: String) throws {
        let mac = app.buttons["home.mac"]
        XCTAssertTrue(mac.waitForExistence(timeout: 10), "the Mac button\n\(app.debugDescription)")
        XCTAssertTrue((mac.value as? String ?? "").contains(detail), "the Mac button's value: \(String(describing: mac.value))")
        mac.tap()
        let header = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", "· \(detail)")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), "the menu's status\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["home.mac.retry"].exists, "Retry in the menu\n\(app.debugDescription)")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

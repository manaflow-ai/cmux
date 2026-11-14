import XCTest

/// CMUX-489, reworked 2026-11-13: Home says its Mac's list is not live the way the Workspaces
/// tab does. Kept rows stay (dimmed) under Workspaces' Mac line ("<Mac> · Offline · last known"
/// or "· Couldn't refresh · last known", Retry), with no card over the list; with nothing kept,
/// Workspaces' empty state for that Mac shows ("Can't connect to …" with Retry, or "… is offline").
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
        let line = app.buttons["home.macStatus"]
        XCTAssertTrue(line.waitForExistence(timeout: 10), "Workspaces' Mac line\n\(app.debugDescription)")
        XCTAssertTrue(line.label.hasSuffix("· Offline · last known"), "the line marks the rows as last known: \(line.label)")
        XCTAssertLessThan(line.frame.maxY, row.frame.minY, "the line sits above the rows")
        XCTAssertFalse(app.descendants(matching: .any)["home.note.problem"].exists, "no card over the kept rows")
        attach(app, "1-home-offline-kept-rows")

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
    func testAFailedReadMarksTheKeptRowsInTheSubtitle() throws {
        let app = launch("retry-home-failed")
        XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "a kept Home row\n\(app.debugDescription)")
        let line = app.buttons["home.macStatus"]
        XCTAssertTrue(line.waitForExistence(timeout: 10), "Workspaces' Mac line\n\(app.debugDescription)")
        XCTAssertTrue(line.label.hasSuffix("· Couldn't refresh · last known"), "the failed read's words: \(line.label)")
        XCTAssertFalse(app.descendants(matching: .any)["home.note.problem"].exists, "no card over the kept rows")
        attach(app, "3-home-failed-kept-rows")
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
        XCTAssertFalse(app.buttons["home.macStatus"].exists, "no line over an empty list")
        XCTAssertFalse(app.staticTexts["No Conversations"].exists, "one empty state, not two")
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

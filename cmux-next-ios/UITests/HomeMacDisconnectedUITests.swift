import XCTest

/// CMUX-489, reworked 2026-11-13: Home says its Mac's list is not live the way the Workspaces
/// tab does: kept rows show exactly as normal under Workspaces' connection toast ("Offline" or
/// "Couldn't refresh", with Retry), which takes its own room and covers no row; with nothing kept, Workspaces' empty state for that Mac shows
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
        // Non-blocking: the kept rows still open.
        row.tap()
        XCTAssertTrue(app.buttons["home.compose"].waitForNonExistence(timeout: 10), "a kept row opens\n\(app.debugDescription)")
        // The conversation itself opens (its header, transcript and composer), never a
        // full-screen error. Chief draws no connection banner (Aziz 2026-11-12): the header
        // says it is connecting and the outbox holds what is written.
        let composer = app.descendants(matching: .any)["conversation.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "the composer\n\(app.debugDescription)")
        // Past the load: the full-screen error (before this change) would have replaced it by now.
        _ = app.buttons["home.conversation.retry"].waitForExistence(timeout: 8)
        attach(app, "2-row-opened-conversation")
        XCTAssertFalse(app.buttons["home.conversation.retry"].exists, "no full-screen error")
        XCTAssertTrue(composer.exists, "the composer stays\n\(app.debugDescription)")
        // Its header names it, from what Home knows, before the Mac answers.
        let name = app.descendants(matching: .any)["conversation.header.name"]
        XCTAssertTrue(name.exists, "the header\n\(app.debugDescription)")
        XCTAssertEqual(name.label, "Conversation 5", "the header names the conversation")

        // Back on Home: the Mac button says it, with Retry; the rows stay after it.
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "back on Home\n\(app.debugDescription)")
        try expectToast(app, saying: "Offline", above: row)
        attach(app, "1b-home-offline-toast")
        app.buttons["Retry"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the rows stay after Retry")
    }

    @MainActor
    func testAFailedReadMarksTheKeptRowsInTheMacMenu() throws {
        let app = launch("retry-home-failed")
        XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "a kept Home row\n\(app.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["home.note.problem"].exists, "no card over the kept rows")
        attach(app, "3-home-failed-kept-rows")
        try expectToast(app, saying: "Couldn't refresh", above: app.buttons["home.row.stress-5"])
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

    /// Workspaces' connection toast: its words and Retry, above the rows (never over them).
    @MainActor
    private func expectToast(_ app: XCUIApplication, saying text: String, above row: XCUIElement) throws {
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 10), "the connection toast\n\(app.debugDescription)")
        let retry = app.buttons["Retry"].firstMatch
        XCTAssertTrue(retry.exists, "Retry on the toast\n\(app.debugDescription)")
        XCTAssertLessThanOrEqual(toast.frame.maxY, row.frame.minY, "the toast covers no row")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

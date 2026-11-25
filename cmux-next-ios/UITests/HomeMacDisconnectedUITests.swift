import XCTest

/// CMUX-489, reworked 2026-11-13: Home says its Mac's list is not live the way the Workspaces
/// tab does: kept rows show exactly as normal; a link that only redials says nothing (Leo's item 3,
/// 2026-11-24), and a failed read shows "Couldn't refresh" with Retry, which takes its own room and covers no row; with nothing kept, Workspaces' empty state for that Mac shows
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

        // Back on Home: the rows stay, and a link that only redials says nothing, past the quiet
        // bound too. On purpose: before Leo's item 3 a "Can't reach" chip with Retry showed here
        // (Leo, 2026-11-24: "let's just keep optimistically connecting and reinforcing the
        // connection ... instead of making the user think they're constsntly suspended in a
        // state of connection limbo").
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "back on Home\n\(app.debugDescription)")
        let limbo = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Can't reach")).firstMatch
        XCTAssertFalse(limbo.waitForExistence(timeout: 14), "a connecting chip over the kept rows\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["connection.chip.retry"].exists, "no chip Retry for a link that redials on its own")
        attach(app, "1b-home-offline-no-chip")
        XCTAssertTrue(row.exists, "the kept rows stay")
    }

    @MainActor
    func testAFailedReadMarksTheKeptRowsInTheMacMenu() throws {
        let launched = Date()
        let app = launch("retry-home-failed")
        XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "a kept Home row\n\(app.debugDescription)")
        try expectNoToastYet(app, saying: "Couldn't refresh", since: launched)
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
        // A link chip waits the 10 s quiet bound before it shows.
        XCTAssertTrue(toast.waitForExistence(timeout: 25), "the connection toast\n\(app.debugDescription)")
        XCTAssertTrue(retryControl(app).exists, "Retry on the toast\n\(app.debugDescription)")
        // A link state is a chip a few words wide floating over the rows, not a full-width
        // row that pushes them down (Leo, 2026-11-21: "stop layout shifting").
        XCTAssertLessThan(toast.frame.width, app.frame.width / 2, "the toast is a chip, not a sentence")
    }

    /// Before the quiet bound has passed, the drawn chip says nothing and takes no tap: the
    /// view itself (opacity 0, hidden from VoiceOver, no hit testing), not only its gate.
    @MainActor
    private func expectNoToastYet(_ app: XCUIApplication, saying text: String, since launched: Date) throws {
        let elapsed = Date().timeIntervalSince(launched)
        // The drop is at launch; under 8 s in, the 10 s bound has surely not passed.
        guard elapsed < 8 else {
            print("HomeMacDisconnected: rows took \(elapsed) s, past the window to check the quiet chip")
            return
        }
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
        XCTAssertFalse(toast.exists, "the chip shows before its 10 s bound (\(elapsed) s in)\n\(app.debugDescription)")
        let retry = retryControl(app)
        XCTAssertFalse(retry.exists && retry.isHittable, "Retry takes a tap before the chip shows (\(elapsed) s in)")
        print("HomeMacDisconnected: no chip and no Retry at \(elapsed) s")
    }

    /// The toast's Retry: the banner's "Retry" button, or the link chip that is its own Retry.
    @MainActor
    private func retryControl(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", "Retry", "connection.chip.retry")).firstMatch
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

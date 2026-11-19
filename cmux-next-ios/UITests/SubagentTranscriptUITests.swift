import XCTest

/// A subagent's transcript and the Subagents list on the list rig's generated chat
/// (`CMUX_MOBILE_LIST_SCREEN=subagent|subagents`, ListStressChatScreens): the "Subagent of" pill,
/// the task, rows, the state footer; a nested subagent's row pushes its own transcript and back
/// pops one level; a Subagents row pushes its transcript; the empty list. Each step attaches a
/// screenshot.
final class SubagentTranscriptUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ screen: String, count: Int, stream: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = screen
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "\(count)"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        if stream { app.launchEnvironment["CMUX_MOBILE_LIST_STREAM"] = "1" }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testNestedSubagentPushesItsTranscriptAndBackPopsOneLevel() {
        let app = launch("subagent", count: 40)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["WireGuard dialer"].waitForExistence(timeout: 40), "the transcript opens\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Subagent of Rig chat"].exists, "the pill names the parent")
        XCTAssertTrue(app.staticTexts["Check the WireGuard dialer's retry path and measure its backoff"].exists, "the task shows")
        attach(app, "1-transcript-top")

        let nested = app.buttons["Relay probe, Done"].firstMatch
        for _ in 0..<12 where !(nested.exists && nested.isHittable) { app.swipeUp() }
        XCTAssertTrue(nested.isHittable, "the nested subagent's row is reachable\n\(app.debugDescription)")
        attach(app, "2-nested-row")
        nested.tap()
        XCTAssertTrue(app.navigationBars["Relay probe"].waitForExistence(timeout: 10), "the nested transcript opens\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Subagent of WireGuard dialer"].exists, "its pill names its parent subagent")
        attach(app, "3-nested-transcript")
        app.navigationBars["Relay probe"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["WireGuard dialer"].waitForExistence(timeout: 10), "back pops one level")
        XCTAssertTrue(nested.isHittable, "back returns to the same place")
        for _ in 0..<12 where !app.staticTexts["Done"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Done"].exists, "the footer says the subagent finished\n\(app.debugDescription)")
        attach(app, "4-footer-done")
    }

    @MainActor
    func testRunningTranscriptStreams() {
        let app = launch("subagent", count: 10, stream: true)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["WireGuard dialer"].waitForExistence(timeout: 40), "the transcript opens\n\(app.debugDescription)")
        // Tokens stream into the running subagent's answer.
        let token = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "token40 ")).firstMatch
        for _ in 0..<12 where !token.exists { app.swipeUp() }
        XCTAssertTrue(token.waitForExistence(timeout: 20), "streamed tokens show\n\(app.debugDescription)")
        attach(app, "running")
    }

    @MainActor
    func testSubagentsListPushesATranscript() {
        let app = launch("subagents", count: 6)
        defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Subagents"].waitForExistence(timeout: 40), "the list opens\n\(app.debugDescription)")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Subagent 1")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "a nested row shows\n\(app.debugDescription)")
        attach(app, "1-list")
        row.tap()
        XCTAssertTrue(app.navigationBars["Subagent 1"].waitForExistence(timeout: 10), "the row pushes its transcript\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Subagent of Subagent 0"].exists, "the pill names its parent")
        attach(app, "2-pushed")
        app.navigationBars["Subagent 1"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Subagents"].waitForExistence(timeout: 10), "back to the list")
    }

    @MainActor
    func testEmptySubagentsList() {
        let app = launch("subagents", count: 0)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["No subagents"].waitForExistence(timeout: 40), "the empty state\n\(app.debugDescription)")
        attach(app, "empty")
    }
}

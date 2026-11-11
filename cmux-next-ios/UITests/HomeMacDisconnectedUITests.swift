import XCTest

/// CMUX-489: when Home's Mac is not connected, Home said so only in small gray text under its
/// last row ("Couldn't load this Mac's Home." and Retry), so the kept list read as live. Now a
/// bar at the top says the Mac is not connected, that the list is the last one this iPhone
/// read, and offers Try Again; the rows under it stay usable.
/// The `retry-home-offline` demo seeds kept rows and marks the Home Mac's link failed.
final class HomeMacDisconnectedUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheDisconnectedBarSitsAtTheTopOverTheKeptRows() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore",
                                "-cmux-mobile-demo", "retry-home-offline"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons.element(boundBy: 0).tap() }

        let row = app.buttons["home.row.stress-5"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "a kept Home row\n\(app.debugDescription)")
        let bar = app.buttons["home.note.problem"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the disconnected bar\n\(app.debugDescription)")
        XCTAssertTrue(bar.label.contains("Not connected to"), "the bar names the dropped Mac: \(bar.label)")
        XCTAssertTrue(bar.label.contains("last list"), "the bar marks the list as kept: \(bar.label)")
        // At the top: above every row, in the upper part of the screen.
        XCTAssertLessThan(bar.frame.maxY, row.frame.minY, "the bar sits above the rows")
        XCTAssertLessThan(bar.frame.midY, app.frame.height / 3, "the bar is at the top of Home")
        attach(app, "1-home-mac-offline")

        // Non-blocking: the kept rows still open.
        row.tap()
        // Home's own toolbar (Compose) leaves when the conversation opens over it.
        let compose = app.buttons["home.compose"]
        XCTAssertTrue(compose.waitForNonExistence(timeout: 10), "a kept row opens its conversation\n\(app.debugDescription)")
        attach(app, "2-row-opened")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

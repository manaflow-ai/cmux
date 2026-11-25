import XCTest

/// A Mac that can't be shared (user 2026-11-13: the "isn't sharing its screen" card came up over
/// the list as soon as + › Screen Sharing opened). Now the sheet stays on the list, and tapping
/// that Mac says why in a native alert. Demo data (`-cmux-mobile-screen-sharing-demo
/// unavailable`): the workspace's Mac (Aziz's Mac Studio) isn't sharing, Office iMac is offline,
/// and mini 1 blocks this iPhone.
final class ScreenSharingUnavailableUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testUnavailableMacsSayWhyInAnAlert() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                "-cmux-mobile-screen-sharing-demo", "unavailable"]
        app.launch()

        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        row.tap()

        let tabsButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 15), "tabs button\n\(app.debugDescription)")
        tabsButton.tap()
        let plus = app.buttons["New"].firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 15), "+ menu\n\(app.debugDescription)")
        plus.tap()
        let entry = app.buttons["Screen Sharing"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Screen Sharing in +\n\(app.debugDescription)")
        entry.tap()

        // The workspace's Mac isn't sharing: the sheet lists it and opens nothing over the list.
        let studio = app.buttons["screenSharing.mac.Aziz's Mac Studio"].firstMatch
        XCTAssertTrue(studio.waitForExistence(timeout: 20), "the Macs list\n\(app.debugDescription)")
        settle(1.5)
        XCTAssertFalse(app.staticTexts["Aziz's Mac Studio isn't sharing its screen"].exists, "no card or alert before a tap")
        XCTAssertTrue(app.navigationBars["Screen Sharing"].exists, "still on the list")
        XCTAssertTrue(studio.isEnabled, "a Mac that can't be shared is still tappable")
        attach(app, "01-list-not-shared-opens-nothing")

        try expectAlert(app, tapping: studio, title: "Aziz's Mac Studio isn't sharing its screen",
                        message: "Turn on Share This Mac in the Mac's Settings › Devices.",
                        buttons: ["Check Again", "OK"], shot: "02-alert-not-shared")
        try expectAlert(app, tapping: app.buttons["screenSharing.mac.Office iMac"].firstMatch, title: "Office iMac is offline",
                        message: "Open cmux on the Mac and make sure it's online.",
                        buttons: ["Check Again", "OK"], shot: "03-alert-offline")
        try expectAlert(app, tapping: app.buttons["screenSharing.mac.mini 1"].firstMatch, title: "mini 1 doesn't allow this iPhone",
                        message: "Change this iPhone's access on the Mac, in Settings › Devices.",
                        buttons: ["Check Again", "OK"], shot: "04-alert-blocked")
    }

    /// Taps `row`, checks the alert's text and buttons, then OK closes it back to the list.
    @MainActor
    private func expectAlert(_ app: XCUIApplication, tapping row: XCUIElement, title: String, message: String,
                             buttons: [String], shot: String) throws {
        XCTAssertTrue(row.waitForExistence(timeout: 10), "row for \(title)\n\(app.debugDescription)")
        row.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "alert for \(title)\n\(app.debugDescription)")
        XCTAssertTrue(alert.staticTexts[title].exists, "title \(title)\n\(alert.debugDescription)")
        XCTAssertTrue(alert.staticTexts[message].exists, "message \(message)\n\(alert.debugDescription)")
        for button in buttons {
            XCTAssertTrue(alert.buttons[button].exists, "button \(button)\n\(alert.debugDescription)")
        }
        settle(0.8)
        attach(app, shot)
        alert.buttons["OK"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 10), "OK closes the alert")
        XCTAssertTrue(app.navigationBars["Screen Sharing"].exists, "back on the list")
        settle(0.5)
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

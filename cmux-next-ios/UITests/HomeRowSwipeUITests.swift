import XCTest

/// Home's (Chief's) rows swipe the way Workspaces' rows do (user request
/// 2026-11-03): a leftward swipe shows the row's trailing actions (Read or
/// Unread, Pin or Unpin); while they are open a rightward swipe closes them and
/// never opens the team drawer; with no row open the same swipe opens it.
/// Home is seeded by the list rig (`CMUX_MOBILE_LIST_SCREEN=home`, no passes).
final class HomeRowSwipeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "home"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "16"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchArguments += ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        return app
    }

    @MainActor
    func testRowSwipeActionsAndTheDrawer() throws {
        let app = launch()
        let drawerOpen = app.buttons["Close teams"]
        // stress-5: read, not pinned.
        let row = app.buttons["home.row.stress-5"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Home row\n\(app.debugDescription)")
        attach(app, "home")

        // Leftward: the trailing actions, as on Workspaces.
        row.swipeLeft()
        let pin = app.buttons["Pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "swipe actions\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Unread"].exists, "Unread swipe action")
        XCTAssertFalse(drawerOpen.exists, "a leftward swipe never opens the drawer")
        attach(app, "swipe-open")

        // While open, a rightward swipe closes the actions, not opening the drawer.
        row.swipeRight()
        XCTAssertTrue(waitGone(app.buttons["Pin"]), "the row's actions closed\n\(app.debugDescription)")
        XCTAssertFalse(drawerOpen.waitForExistence(timeout: 1.5), "the drawer stayed shut while a row was open")
        attach(app, "swipe-closed")

        // Pin from the swipe: the row becomes a pinned tile.
        row.swipeLeft()
        XCTAssertTrue(app.buttons["Pin"].waitForExistence(timeout: 5), "swipe actions again\n\(app.debugDescription)")
        app.buttons["Pin"].tap()
        XCTAssertTrue(app.buttons["home.pin.stress-5"].waitForExistence(timeout: 5), "pinned from the swipe\n\(app.debugDescription)")
        attach(app, "pinned")

        // An unread row offers Read; it closes with a rightward swipe too.
        let unread = app.buttons["home.row.stress-6"]
        XCTAssertTrue(unread.waitForExistence(timeout: 5), "unread row")
        unread.swipeLeft()
        XCTAssertTrue(app.buttons["Read"].waitForExistence(timeout: 5), "Read swipe action\n\(app.debugDescription)")
        unread.swipeRight()
        XCTAssertTrue(waitGone(app.buttons["Read"]), "closed")
        XCTAssertFalse(drawerOpen.waitForExistence(timeout: 1.5), "the drawer stayed shut")

        // No row open: the rightward swipe opens the drawer.
        unread.swipeRight()
        XCTAssertTrue(drawerOpen.waitForExistence(timeout: 5), "the drawer opens with no row open\n\(app.debugDescription)")
        attach(app, "drawer")
    }

    private func waitGone(_ element: XCUIElement) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: 5) == .completed
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

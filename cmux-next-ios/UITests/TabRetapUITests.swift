import XCTest

/// A tap on the tab that is already selected (the iOS Mail pattern): a pushed page pops back to the
/// tab's root, and at the root the tab's list scrolls to its top. On the Feed, reaching the top that
/// way also clears the "N new" pill, as scrolling there by hand does.
///
/// Before, the tap did nothing on the Feed: the reader had to drag all the way back up.
final class TabRetapUITests: XCTestCase {
    /// The Feed, scrolled far down: a tap on the Feed tab brings its first row back.
    @MainActor
    func testFeedTabRetapScrollsToTop() {
        let app = launch(tab: "feed", environment: ["CMUX_MOBILE_FEED_STRESS": "300"])
        let all = feedChipsAfterSetup(app)
        let topFrame = all.frame
        let list = app.tables["feed.list"]
        let rows = list.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed.row."))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "Feed rows\n\(app.debugDescription)")
        let first = list.cells[rows.firstMatch.identifier]
        XCTAssertTrue(first.isHittable, "the first row shows at launch")

        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        XCTAssertFalse(all.isHittable, "did not scroll away from the top")
        XCTAssertFalse(first.exists && first.isHittable, "the first row still shows after scrolling down")
        attachBothLooks(app, "feed-scrolled-down")

        // Leaving the tab and coming back is not a re-tap: the Feed keeps its place.
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15), "Settings\n\(app.debugDescription)")
        app.tabBars.buttons["Feed"].tap()
        XCTAssertTrue(app.navigationBars["Feed"].waitForExistence(timeout: 15), "back on the Feed\n\(app.debugDescription)")
        let settle = XCTestExpectation(description: "no scroll follows the tab change")
        settle.isInverted = true
        _ = XCTWaiter.wait(for: [settle], timeout: 2)
        XCTAssertFalse(all.isHittable, "changing tabs scrolled the Feed to its top")

        app.tabBars.buttons["Feed"].tap()
        let landed = NSPredicate { _, _ in
            first.exists && first.isHittable && all.exists && abs(all.frame.minY - topFrame.minY) < 1
        }
        XCTAssertEqual(wait(landed, "Feed back at its top", timeout: 30), .completed,
                       "after the tab tap: chips at \(all.exists ? "\(all.frame)" : "gone"), expected \(topFrame)")
        XCTAssertTrue(app.navigationBars["Feed"].exists, "the Feed stays the screen shown")
        attachBothLooks(app, "feed-after-tab-tap")
    }

    /// New events wait above the reader ("N new"): the tab tap lands at the top and the pill goes.
    @MainActor
    func testFeedTabRetapClearsNewPill() {
        let app = launch(tab: "feed", environment: ["CMUX_MOBILE_FEED_STRESS": "300", "CMUX_MOBILE_FEED_STRESS_LIVE": "3"])
        let all = feedChipsAfterSetup(app)
        // The Finished filter: no open asks pinned above the events, so live events arrive on top.
        app.buttons["Finished"].firstMatch.tap()
        let topFrame = all.frame
        for _ in 0..<8 { app.swipeUp(velocity: .fast) }
        let pill = app.buttons["feed.newPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "no new pill after scrolling down")
        attach(app, "pill-before-tab-tap")

        app.tabBars.buttons["Feed"].tap()
        let landed = NSPredicate { _, _ in all.exists && abs(all.frame.minY - topFrame.minY) < 1 }
        XCTAssertEqual(wait(landed, "Feed back at its top", timeout: 60), .completed,
                       "after the tab tap: chips at \(all.exists ? "\(all.frame)" : "gone"), expected \(topFrame)")
        XCTAssertTrue(pill.waitForNonExistence(timeout: 10), "pill still shown at the top")
        XCTAssertTrue(app.navigationBars["Feed"].exists, "the Feed stays the screen shown")
        attach(app, "pill-after-tab-tap")
    }

    /// Settings, scrolled to its end: a tap on the Settings tab scrolls it back to its top.
    @MainActor
    func testSettingsTabRetapScrollsToTop() {
        let app = launch(tab: "settings")
        let tab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "tab bar\n\(app.debugDescription)")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15), "Settings\n\(app.debugDescription)")
        let signOut = app.buttons["settings.logout"]
        for _ in 0..<5 where !(signOut.exists && signOut.isHittable) { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(signOut.exists && signOut.isHittable, "Settings did not scroll to its end\n\(app.debugDescription)")
        attach(app, "settings-scrolled-down")

        tab.tap()
        let left = NSPredicate { _, _ in !(signOut.exists && signOut.isHittable) }
        XCTAssertEqual(wait(left, "Settings back at its top", timeout: 20), .completed, "Sign out still shows after the tab tap")
        attach(app, "settings-after-tab-tap")
    }

    /// A Settings page (the tab bar stays on those): a tap on the Settings tab pops back to Settings.
    @MainActor
    func testSettingsTabRetapPopsToRoot() {
        let app = launch(tab: "settings", arguments: ["-cmux-mobile-settings-page", "acknowledgements"])
        let tab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "tab bar\n\(app.debugDescription)")
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15), "navigation bar\n\(app.debugDescription)")
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 15), "the page is not pushed\n\(app.debugDescription)")
        attach(app, "settings-page-pushed")

        tab.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15), "the page did not pop\n\(app.debugDescription)")
        XCTAssertTrue(tab.isSelected, "Settings stays the selected tab")
        attach(app, "settings-after-tab-tap-root")
    }

    // MARK: Helpers

    @MainActor
    private func launch(tab: String, environment: [String: String] = [:], arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launchArguments += ["-cmux-mobile-tab", tab, "-cmux-mobile-no-restore"] + arguments
        app.launch()
        // First run of mock data: pick the team (the Feed's own helper does it for the Feed).
        if tab != "feed" {
            let choose = app.scrollViews["setup.teams.choose"]
            if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        }
        return app
    }

    @MainActor
    private func wait(_ predicate: NSPredicate, _ what: String, timeout: TimeInterval) -> XCTWaiter.Result {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription = what
        return XCTWaiter.wait(for: [expectation], timeout: timeout)
    }

    /// The same screen in light and in dark (NAME-light, NAME-dark); the device's look is put back.
    @MainActor private func attachBothLooks(_ app: XCUIApplication, _ name: String) {
        let before = XCUIDevice.shared.appearance
        for (look, suffix) in [(XCUIDevice.Appearance.light, "light"), (.dark, "dark")] {
            XCUIDevice.shared.appearance = look
            let settle = XCTestExpectation(description: "the look change settles")
            settle.isInverted = true
            _ = XCTWaiter.wait(for: [settle], timeout: 1)
            attach(app, "\(name)-\(suffix)")
        }
        XCUIDevice.shared.appearance = before
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

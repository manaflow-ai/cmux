import XCTest

/// Show more and Show less on a Feed row leave the list where it is: the row's top stays put and
/// only what is below it moves.
///
/// Before the fix, the list kept the row *below* the toggled one in place, so when the toggled row
/// was the first on screen, expanding it pushed its top (and everything above) up by the new
/// height, and collapsing pulled it down: the viewport jumped on every tap.
final class FeedShowMoreAnchorUITests: XCTestCase {
    @MainActor
    func testShowMoreAndShowLessKeepTheRowInPlace() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // A fixed Feed with long bodies and no live traffic: only the tap moves anything.
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "60"
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        XCTAssertTrue(app.buttons["All"].firstMatch.waitForExistence(timeout: 30), "Feed chips\n\(app.debugDescription)")

        let list = app.tables["feed.list"]
        let bar = app.navigationBars["Feed"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))

        // The first row with a Show more on screen, scrolled until its top sits just under the bar:
        // the first row shown, the case that jumped.
        var more = app.buttons["Show more"].firstMatch
        for _ in 0..<12 where !(more.exists && more.isHittable) {
            app.swipeUp(velocity: .slow)
            more = app.buttons["Show more"].firstMatch
        }
        XCTAssertTrue(more.isHittable, "no Show more on screen\n\(app.debugDescription)")
        let cell = list.cells.containing(.button, identifier: "Show more").firstMatch
        let cellID = cell.identifier
        XCTAssertTrue(cellID.hasPrefix("feed.row."), "row cell id: \(cellID)")
        let row = list.cells[cellID]
        let target = bar.frame.maxY + 4
        let from = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 2))
        let drag = row.frame.minY - target
        if abs(drag) > 2 {
            // A held drag has no fling: the list stops where the finger does.
            from.press(forDuration: 0.1, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -drag)), withVelocity: .slow,
                       thenHoldForDuration: 0.5)
        }
        settle(row)
        let restTop = row.frame.minY
        let rowMore = row.buttons["Show more"]
        XCTAssertTrue(rowMore.isHittable, "Show more not on screen after placing the row (top \(restTop))\n\(app.debugDescription)")
        attach(app, "before-show-more")

        rowMore.tap()
        let less = row.buttons["Show less"]
        XCTAssertTrue(less.waitForExistence(timeout: 5), "row did not expand")
        settle(row)
        attach(app, "after-show-more")
        XCTAssertEqual(row.frame.minY, restTop, accuracy: 1, "Show more moved the row's top")

        // Show less: back where it was, with the same top.
        if less.isHittable {
            less.tap()
            XCTAssertTrue(row.buttons["Show more"].waitForExistence(timeout: 5), "row did not collapse")
            settle(row)
            attach(app, "after-show-less")
            XCTAssertEqual(row.frame.minY, restTop, accuracy: 1, "Show less moved the row's top")
        }
    }

    /// Waits until the row's frame stops changing (the resize animation ended).
    @MainActor private func settle(_ row: XCUIElement) {
        var last = row.frame
        let still = NSPredicate { _, _ in
            let now = row.frame
            defer { last = now }
            return now == last
        }
        let wait = expectation(for: still, evaluatedWith: nil)
        _ = XCTWaiter.wait(for: [wait], timeout: 3)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

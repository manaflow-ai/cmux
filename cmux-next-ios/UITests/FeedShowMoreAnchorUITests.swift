import XCTest

/// Show more on a Feed row leaves the list where it is: the row's top stays put and only what is
/// below it moves, also when that top has scrolled under the bar.
///
/// Before the fix, the list kept the row *below* the toggled one in place, so when the toggled row
/// was the first on screen (its top under the bar), expanding it pushed its top and the text being
/// read up by the new height: the viewport jumped on the tap.
final class FeedShowMoreAnchorUITests: XCTestCase {
    @MainActor
    func testShowMoreAndShowLessKeepTheRowInPlace() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // A fixed Feed with long bodies and no live traffic: only the tap moves anything.
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "60"
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        _ = feedChipsAfterSetup(app)

        // The Finished filter: plain events only (no pinned asks), most with long bodies.
        app.buttons["Finished"].firstMatch.tap()
        let list = app.tables["feed.list"]
        let bar = app.navigationBars["Feed"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let tabBarTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : list.frame.maxY

        // A row with a Show more whose top can sit just under the bar with its Show more still on
        // screen: one snapshot of the table per look (frames for every cell in one query).
        func rows() -> [(id: String, top: CGFloat, more: CGFloat)] {
            guard let snap = try? list.snapshot() else { return [] }
            return snap.children.compactMap { cell in
                guard cell.identifier.hasPrefix("feed.row.") else { return nil }
                func find(_ e: XCUIElementSnapshot) -> XCUIElementSnapshot? {
                    if e.elementType == .button, e.label == "Show more" { return e }
                    for child in e.children { if let hit = find(child) { return hit } }
                    return nil
                }
                guard let more = find(cell) else { return nil }
                return (cell.identifier, cell.frame.minY, more.frame.maxY - cell.frame.minY)
            }
        }
        let barBottom = bar.frame.maxY
        // The row's top this far under the bar: the first row on screen, partly read, the case that
        // jumped (the list kept the row after it, so the growing row pushed its own top up).
        let under: CGFloat = 30
        func pick() -> (id: String, top: CGFloat)? {
            rows().first { $0.top > barBottom + 20 && $0.top - under + $0.more < tabBarTop - 40 }.map { ($0.id, $0.top) }
        }
        var found = pick()
        for _ in 0..<15 where found == nil {
            app.swipeUp(velocity: .slow)
            found = pick()
        }
        guard let found else { return XCTFail("no row with Show more on screen\n\(app.debugDescription)") }
        let row = list.cells[found.id]
        // A held drag has no fling: the list stops where the finger does.
        for _ in 0..<3 {
            let drag = row.frame.minY - (barBottom - under)
            if abs(drag) < 3 { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0)).withOffset(CGVector(dx: 0, dy: tabBarTop - 60))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -drag)), withVelocity: .slow,
                        thenHoldForDuration: 0.6)
            settle(row)
        }
        let restTop = row.frame.minY
        XCTAssertEqual(restTop, barBottom - under, accuracy: 12, "could not place the row under the bar")
        let rowMore = row.buttons.matching(NSPredicate(format: "label == 'Show more'")).firstMatch
        XCTAssertTrue(rowMore.isHittable, "Show more not on screen after placing the row (top \(restTop))\n\(app.debugDescription)")
        attach(app, "before-show-more")

        rowMore.tap()
        let less = row.buttons.matching(NSPredicate(format: "label == 'Show less'")).firstMatch
        XCTAssertTrue(less.waitForExistence(timeout: 5), "row did not expand")
        settle(row)
        attach(app, "after-show-more")
        XCTAssertEqual(row.frame.minY, restTop, accuracy: 1, "Show more moved the row's top")

        // Show less with the row's top still under the bar: the row's end stays near where the person
        // tapped, so its Show more is back on screen (not left far above it).
        if less.isHittable {
            less.tap()
            let moreAgain = row.buttons.matching(NSPredicate(format: "label == 'Show more'")).firstMatch
            XCTAssertTrue(moreAgain.waitForExistence(timeout: 5), "row did not collapse")
            settle(row)
            attach(app, "after-show-less")
            XCTAssertTrue(moreAgain.isHittable, "Show less left the row off screen (top \(row.frame.minY))")
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

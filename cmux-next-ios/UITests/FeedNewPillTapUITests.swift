import XCTest

/// The "N new" pill takes every tap on it, and the jump it starts always lands at the top.
///
/// Before the fix, a tap on the pill's glass edge (outside its icon and text) fell through to the
/// Feed row under it and opened that row, and a second quick tap (the pill vanished at the first)
/// landed on a row mid-jump: it opened that row and stopped the jump short of the top.
final class FeedNewPillTapUITests: XCTestCase {
    /// A tap near each edge of the pill, where its glass shows but its label does not.
    @MainActor
    func testNewPillEdgeTapsJumpToTop() {
        let (app, all, topFrame) = launchFeed(liveHz: 3)
        let edges: [(String, CGVector)] = [("left", CGVector(dx: 0.05, dy: 0.5)), ("top", CGVector(dx: 0.5, dy: 0.1)),
                                           ("right", CGVector(dx: 0.95, dy: 0.5)), ("bottom", CGVector(dx: 0.5, dy: 0.9))]
        for (round, (name, offset)) in edges.enumerated() {
            let pill = scrollAway(app, all, round: round, swipes: 12)
            attach(app, "\(name)-before-tap")
            pill.coordinate(withNormalizedOffset: offset).tap()
            assertLandedAtTop(app, all, topFrame, "\(name) edge")
            attach(app, "\(name)-after-tap")
        }
    }

    /// Two quick taps on the pill: the second must not reach a row while the list moves.
    @MainActor
    func testNewPillDoubleTapLandsAtTopAndOpensNothing() {
        let (app, all, topFrame) = launchFeed(liveHz: 3)
        for round in 0..<3 {
            let pill = scrollAway(app, all, round: round, swipes: 30)
            attach(app, "double\(round)-before-tap")
            pill.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
            assertLandedAtTop(app, all, topFrame, "double tap \(round)")
            attach(app, "double\(round)-after-tap")
        }
    }

    /// Many unseen events wait above the reader (the person's suspicion): the jump still lands at the top.
    @MainActor
    func testNewPillWithManyUnseenAboveLandsAtTop() {
        let (app, all, topFrame) = launchFeed(liveHz: 4)
        for round in 0..<3 {
            let pill = scrollAway(app, all, round: round, swipes: 8)
            // A new event a second arrives above: wait until a lot are waiting. (Faster live rates starve
            // the list's off-main row layout on a simulator: it shows no change at all.)
            let many = NSPredicate { _, _ in
                guard pill.exists, let count = pill.label.split(separator: " ").compactMap({ Int($0) }).first else { return false }
                return count >= 25
            }
            let wait = expectation(for: many, evaluatedWith: nil)
            wait.expectationDescription = "round \(round): 25 new events above"
            XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 90), .completed, "round \(round): pill says \(pill.label)")
            attach(app, "many\(round)-before-tap")
            pill.tap()
            assertLandedAtTop(app, all, topFrame, "many unseen \(round)")
            attach(app, "many\(round)-after-tap")
        }
    }

    // MARK: Helpers

    @MainActor
    private func launchFeed(liveHz: Int) -> (XCUIApplication, XCUIElement, CGRect) {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "300"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS_LIVE"] = "\(liveHz)"
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let all = app.buttons["All"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 30), "Feed chips\n\(app.debugDescription)")
        // The Finished filter: no open asks pinned above the events (FeedStore.pinningNeedsYou), so
        // the rig's live responses arrive on top, above the reader, as the pill counts them.
        app.buttons["Finished"].firstMatch.tap()
        return (app, all, all.frame)
    }

    @MainActor
    private func scrollAway(_ app: XCUIApplication, _ all: XCUIElement, round: Int, swipes: Int) -> XCUIElement {
        for _ in 0..<swipes { app.swipeUp(velocity: .fast) }
        XCTAssertFalse(all.isHittable, "round \(round): did not scroll away from the top")
        let pill = app.buttons["feed.newPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "round \(round): no new pill")
        return pill
    }

    /// The Feed is still the screen shown (no row opened) and its chips are back where they were at launch.
    @MainActor
    private func assertLandedAtTop(_ app: XCUIApplication, _ all: XCUIElement, _ topFrame: CGRect, _ what: String) {
        let landed = NSPredicate { _, _ in all.exists && all.isHittable && all.frame == topFrame }
        let wait = expectation(for: landed, evaluatedWith: nil)
        wait.expectationDescription = "\(what): Feed at its top"
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 5), .completed,
                       "\(what): chips at \(all.exists ? "\(all.frame)" : "gone"), expected \(topFrame)\n\(app.debugDescription)")
        XCTAssertTrue(app.navigationBars["Feed"].exists, "\(what): a row opened instead of the Feed staying shown")
        // Back to the Feed for the next round when a row opened.
        let back = app.navigationBars.buttons.firstMatch
        if !app.navigationBars["Feed"].exists, back.exists { back.tap() }
        let pill = app.buttons["feed.newPill"]
        XCTAssertFalse(pill.exists, "\(what): pill still shown at the top")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

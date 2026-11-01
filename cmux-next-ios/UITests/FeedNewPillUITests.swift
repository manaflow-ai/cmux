import XCTest

/// The "N new" pill lands the Feed exactly at its top from anywhere, including near the
/// bottom of a long Feed while live events keep arriving (stress rig: 300 rows, 8 changes
/// a second). Before the fix, a live update applied during the jump restored the reader's
/// anchor, which set the offset and cut the jump's animation short mid-list.
final class FeedNewPillUITests: XCTestCase {
    @MainActor
    func testNewPillFromNearBottomLandsAtTop() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "300"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS_LIVE"] = "8"
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }

        let all = app.buttons["All"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 30), "Feed chips\n\(app.debugDescription)")
        let topFrame = all.frame

        for round in 0..<3 {
            // Far down the list, near its bottom.
            for _ in 0..<(round == 0 ? 40 : 25) { app.swipeUp(velocity: .fast) }
            XCTAssertFalse(all.isHittable, "round \(round): did not scroll away from the top")
            let pill = app.buttons["feed.newPill"]
            XCTAssertTrue(pill.waitForExistence(timeout: 20), "round \(round): no new pill")
            attach(app, "round\(round)-before-tap")
            pill.tap()
            // The jump ends: the chips are back, exactly where they were at launch.
            let landed = NSPredicate { _, _ in all.exists && all.isHittable && all.frame == topFrame }
            let wait = expectation(for: landed, evaluatedWith: nil)
            wait.expectationDescription = "round \(round): Feed at its top"
            XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 5), .completed,
                           "round \(round): chips at \(all.frame), expected \(topFrame)")
            XCTAssertFalse(pill.exists, "round \(round): pill still shown at the top")
            attach(app, "round\(round)-after-tap")
        }
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

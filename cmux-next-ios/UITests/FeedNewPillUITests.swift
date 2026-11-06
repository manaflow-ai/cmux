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
        // 3 changes a second: at 8 the list's off-main row layout never catches up on a simulator
        // and it shows no new event (no pill) at all.
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS_LIVE"] = "3"
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()

        let all = feedChipsAfterSetup(app)
        // The Finished filter: no open asks pinned above the events (FeedStore.pinningNeedsYou), so
        // the rig's live responses arrive on top, above the reader, as the pill counts them.
        app.buttons["Finished"].firstMatch.tap()
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
            let landed = NSPredicate { _, _ in all.exists && abs(all.frame.minY - topFrame.minY) < 1 }
            let wait = expectation(for: landed, evaluatedWith: nil)
            wait.expectationDescription = "round \(round): Feed at its top"
            XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 60), .completed,
                           "round \(round): chips at \(all.frame), expected \(topFrame)")
            XCTAssertTrue(pill.waitForNonExistence(timeout: 10), "round \(round): pill still shown at the top")
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

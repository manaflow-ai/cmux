import XCTest

/// Switching the Feed between its filters while scrolled down a long, live Feed. Each switch
/// shrinks or grows the list in one snapshot. Before the fix, UIKit asked FeedListLayout for
/// the visible cells before its layout pass and it read row heights past the new end: the
/// TestFlight crash on switching sections (cmux INTERNAL 1.2.0, 20261026223529 and 20261031011229).
final class FeedFilterSwitchUITests: XCTestCase {
    @MainActor
    func testSwitchingFiltersMidListDoesNotCrash() {
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
        let chips = ["Needs you", "Finished", "Errors", "All"]
        for round in 0..<2 {
            // Away from the top, so the shrunk list has fewer rows than the old visible range.
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            for name in chips {
                // The chips scroll with the list: back to the top to reach them, then switch.
                let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
                var swipes = 0
                while !(chip.exists && chip.isHittable), swipes < 30 {
                    app.swipeDown(velocity: .fast)
                    swipes += 1
                }
                guard chip.exists, chip.isHittable else {
                    XCTFail("round \(round): chip \(name) never reachable\n\(app.debugDescription)")
                    return
                }
                chip.tap()
                attach(app, "round\(round)-\(name)")
                app.swipeUp(velocity: .fast)
                XCTAssertEqual(app.state, .runningForeground, "round \(round): the app quit after \(name)")
            }
            attach(app, "round\(round)")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

import XCTest

/// New events spring in at the top of the Feed while the reader sits there (hq docs/design/ios-feed.md item K):
/// the top row changes to the new event, the reader stays at the top, and no "N new" pill appears (the pill is for a
/// reader scrolled away). Run with the sim script's `video` mode to record the arrivals.
final class FeedSpringInsertUITests: XCTestCase {
    @MainActor
    func testLiveEventsSpringInAtTheTop() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "40"
        // Slow traffic, so each arrival reads as one event landing.
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS_LIVE"] = "0.7"
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()

        let all = feedChipsAfterSetup(app)
        // Finished: no open asks pinned above the events, so the live responses land on top.
        app.buttons["Finished"].firstMatch.tap()
        let topFrame = all.frame
        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))

        func topRow() -> String? {
            guard let snap = try? list.snapshot() else { return nil }
            return snap.children.filter { $0.identifier.hasPrefix("feed.row.") }
                .min { $0.frame.minY < $1.frame.minY }?.identifier
        }
        var seen: [String] = []
        if let first = topRow() { seen.append(first) }
        let pill = app.buttons["feed.newPill"]
        let deadline = Date().addingTimeInterval(40)
        while seen.count < 4, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if let row = topRow(), row != seen.last { seen.append(row) }
            XCTAssertFalse(pill.exists, "a reader at the top got the new pill, not the arrival")
        }
        XCTAssertGreaterThanOrEqual(seen.count, 3, "new events did not arrive at the top: \(seen)")
        XCTAssertLessThan(abs(all.frame.minY - topFrame.minY), 1, "the reader left the top: \(all.frame) vs \(topFrame)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "after-arrivals"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

import XCTest

/// The Feed makes spare row cells while idle and the first scroll takes them (FeedListController
/// `spares`). A spare was last filled with a warm-up row: each row it shows after the scroll must
/// be its own event, never a warm-up's or another row's. A quoted stress event carries its own
/// number in its quote ("Request N: …", `FeedStore.stressItem`), so a row whose cell shows another
/// number's quote is a stale cell.
final class FeedSpareCellsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRowsAfterAnIdleScrollShowTheirOwnEvents() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "60"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "feed"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons["Manaflow"].tap() }
        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 40), "the Feed's table\n\(app.debugDescription)")
        XCTAssertTrue(list.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.stress-'")).firstMatch
            .waitForExistence(timeout: 20), "the stress events\n\(app.debugDescription)")
        // Idle: the warm-up and the spare cells (one per idle run-loop turn).
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "idle")], timeout: 4)
        var checked = 0
        for step in 0..<12 {
            list.swipeUp(velocity: .slow)
            for cell in list.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.stress-'")).allElementsBoundByIndex
            where cell.isHittable {
                guard let number = Int(cell.identifier.dropFirst("feed.row.stress-".count)) else { continue }
                let quotes = cell.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Request '")).allElementsBoundByIndex.map(\.label)
                for quote in quotes {
                    XCTAssertTrue(quote.hasPrefix("Request \(number):"),
                                  "row stress-\(number) shows another event's quote after scroll step \(step): \(quote)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 5, "too few quoted rows were checked")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "feed-spares-after-scroll"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

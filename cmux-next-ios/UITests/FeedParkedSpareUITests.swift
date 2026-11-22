import XCTest

/// The Feed parks one spare row cell off screen before its first scroll (FeedListController
/// `spare`). Parked, it is invisible to everything: the UI test's cells and the accessibility
/// elements are the list's rows, each once, none beside the list.
final class FeedParkedSpareUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheParkedSpareIsNotACellOrAnAccessibilityElement() {
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
        let rows = list.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "the events\n\(app.debugDescription)")
        // Still for a while: the spare is built and parked (0.5 s of stillness, one idle build).
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "idle")], timeout: 3)
        // A table's accessibility lists its rows past the screen too (at their row frames, inside
        // the list's width): a parked spare would be a second copy of a row's identifier, or an
        // element beside the list (its holder sits off the window to the left).
        let frame = list.frame
        var seen: Set<String> = []
        for cell in rows.allElementsBoundByIndex {
            XCTAssertTrue(seen.insert(cell.identifier).inserted, "\(cell.identifier) is listed twice (a parked copy)")
        }
        let elements = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.stress-'"))
        var ids: [String: Int] = [:]
        for element in elements.allElementsBoundByIndex {
            ids[element.identifier, default: 0] += 1
            XCTAssertTrue(element.frame.minX >= frame.minX - 0.5 && element.frame.maxX <= frame.maxX + 0.5,
                          "\(element.identifier) at \(element.frame) is beside the list \(frame): a parked cell is an element")
        }
        XCTAssertTrue(ids.values.allSatisfy { $0 == 1 }, "an event is two accessibility elements: \(ids.filter { $0.value > 1 })")
        XCTAssertEqual(elements.count, seen.count, "accessibility elements \(elements.count) vs the list's rows \(seen.count)")
    }
}

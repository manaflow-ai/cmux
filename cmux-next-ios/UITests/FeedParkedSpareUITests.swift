import XCTest

/// The Feed parks one spare row cell off screen before its first scroll (FeedListController
/// `spare`). Parked, it is invisible to everything: the UI test's cells and the accessibility
/// elements are the list's rows, each once, none beside the list.
final class FeedParkedSpareUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The checks against what the list shows: an event listed twice, or an element beside the
    /// list. Returns the problems found (empty: the parked spare is invisible).
    @MainActor
    private func problems(mutant: Bool) -> [String] {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "60"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "feed"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        if mutant { app.launchEnvironment["CMUX_MOBILE_FEED_SPARE_MUTANT"] = "visible" }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons["Manaflow"].tap() }
        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 40), "the Feed's table\n\(app.debugDescription)")
        let rows = list.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "the events\n\(app.debugDescription)")
        // Still for a while: the spare is built and parked (0.5 s of stillness, one idle build). The
        // list's DEBUG value is its trace ("spare made …"): the check below means nothing without it.
        let made = NSPredicate { _, _ in (list.value as? String ?? "").contains("spare made") }
        let built = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: made, object: nil)], timeout: 15) == .completed
        XCTAssertTrue(built, "no spare was built while the Feed was still; list trace:\n\(list.value as? String ?? "-")")
        if !built { return ["no spare was built"] }
        // A table's accessibility lists its rows past the screen too (at their row frames, inside
        // the list's width): a parked spare would be a second copy of a row's identifier, or an
        // element beside the list (its holder sits off the window to the left).
        let frame = list.frame
        var found: [String] = []
        var seen: Set<String> = []
        for cell in rows.allElementsBoundByIndex where !seen.insert(cell.identifier).inserted {
            found.append("\(cell.identifier) is listed twice (a parked copy)")
        }
        let elements = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.stress-'"))
        var ids: [String: Int] = [:]
        for element in elements.allElementsBoundByIndex {
            ids[element.identifier, default: 0] += 1
            if element.frame.minX < frame.minX - 0.5 || element.frame.maxX > frame.maxX + 0.5 {
                found.append("\(element.identifier) at \(element.frame) is beside the list \(frame)")
            }
        }
        for (id, count) in ids where count > 1 { found.append("\(id) is \(count) accessibility elements") }
        // The parked spare's own identifier: never an element.
        let parked = app.descendants(matching: .any).matching(identifier: "feed.spare.parked")
        if parked.count > 0 { found.append("the parked spare is \(parked.count) accessibility element(s) at \(parked.firstMatch.frame)") }
        // Two row elements on top of each other (a spare over a row).
        let frames = elements.allElementsBoundByIndex.map { ($0.identifier, $0.frame) }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] {
                let overlap = a.1.intersection(b.1)
                if !overlap.isNull, overlap.height > 1, overlap.width > 1 { found.append("\(a.0) and \(b.0) overlap by \(overlap.height) pt") }
            }
        }
        if elements.count != seen.count { found.append("accessibility elements \(elements.count) vs the list's rows \(seen.count)") }
        return found
    }

    @MainActor
    func testTheParkedSpareIsNotACellOrAnAccessibilityElement() {
        let found = problems(mutant: false)
        XCTAssertTrue(found.isEmpty, found.joined(separator: "\n"))
    }

    /// The red for the test above: a spare parked in the table at a row's frame, readable
    /// (DEBUG `CMUX_MOBILE_FEED_SPARE_MUTANT=visible`). The same checks must find it.
    @MainActor
    func testAVisibleParkedSpareIsCaught() {
        let found = problems(mutant: true)
        XCTAssertFalse(found.isEmpty, "the checks did not catch a spare parked visibly in the list")
        XCTAssertFalse(found == ["no spare was built"], "the mutant built no spare, so it proves nothing")
    }
}

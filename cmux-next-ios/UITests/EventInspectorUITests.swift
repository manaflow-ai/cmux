import XCTest

/// The Event Inspector (agent chat > Session Info > Event Inspector) on the list rig's journal
/// (`CMUX_MOBILE_LIST_SCREEN=inspector`, ListStressChatScreens): rows newest first, the header
/// count, Filter with results and with none, a record's detail (cut over 20,000 characters),
/// Copy as JSON Lines, Clear, and the two empty states. Each step attaches a screenshot.
final class EventInspectorUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(count: Int, live: Double? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "inspector"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "\(count)"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        if let live { app.launchEnvironment["CMUX_MOBILE_LIST_LIVE_HZ"] = "\(live)" }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Event Inspector"].waitForExistence(timeout: 40), "the inspector opens\n\(app.debugDescription)")
        return app
    }

    @MainActor
    private func header(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["chat.inspector.count"].firstMatch
    }

    @MainActor
    private func expectHeader(_ app: XCUIApplication, _ label: String, _ why: String) {
        let element = header(app)
        let predicate = NSPredicate(format: "label == %@", label)
        let met = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10) == .completed
        XCTAssertTrue(met, "\(why): header is '\(element.exists ? element.label : "missing")', expected '\(label)'")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func filter(_ app: XCUIApplication, _ text: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the Filter field shows\n\(app.debugDescription)")
        field.tap()
        // The field's own clear button, not delete keys (keystrokes can drop on a loaded simulator).
        let clear = field.buttons["Clear text"].firstMatch
        if clear.exists { clear.tap() }
        let empty = NSPredicate(format: "value == nil OR value == '' OR value == 'Filter'")
        let cleared = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: empty, object: field)], timeout: 5) == .completed
        XCTAssertTrue(cleared, "the Filter field is empty before typing, holds '\(field.value as? String ?? "")'")
        if !text.isEmpty { field.typeText(text) }
        attach(app, "filter-\(text.isEmpty ? "cleared" : text)")
    }

    @MainActor
    func testRowsFilterDetailCopyAndClear() {
        let app = launch(count: 40)
        defer { app.terminate() }
        expectHeader(app, "40 events", "a 40-record journal")
        let rows = app.buttons.matching(identifier: "chat.inspector.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "rows show\n\(app.debugDescription)")
        // Newest first: seq 40 on top.
        XCTAssertTrue(rows.firstMatch.label.contains("seq 40"), "the newest row is first, got '\(rows.firstMatch.label)'")
        attach(app, "1-rows")

        // Filter: tool_call and tool_call_update records (2 of every 5).
        filter(app, "tool_call")
        expectHeader(app, "16 of 40 events", "the filter keeps the tool records")
        XCTAssertTrue(rows.firstMatch.label.contains("tool_call"), "a filtered row is a tool record, got '\(rows.firstMatch.label)'")
        attach(app, "2-filter-results")
        filter(app, "zzzz-no-such-record")
        expectHeader(app, "0 of 40 events", "a filter with no results")
        XCTAssertFalse(rows.firstMatch.exists, "no rows for a filter with no results")
        attach(app, "3-filter-no-results")
        filter(app, "")
        expectHeader(app, "40 events", "clearing the filter restores every row")

        // A record's detail: the pretty JSON; the 160 KB record (seq 25) is cut, with its note.
        rows.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.inspector.json"].firstMatch.waitForExistence(timeout: 10),
                      "the detail shows the record's JSON\n\(app.debugDescription)")
        attach(app, "4-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        filter(app, "seq 25")
        let big = rows.matching(NSPredicate(format: "label CONTAINS %@", "seq 25")).firstMatch
        XCTAssertTrue(big.waitForExistence(timeout: 10), "the large record is listed\n\(app.debugDescription)")
        big.tap()
        let cut = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Cut at ")).firstMatch
        XCTAssertTrue(cut.waitForExistence(timeout: 10), "a record over 20,000 characters says where it is cut\n\(app.debugDescription)")
        attach(app, "5-detail-cut")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        filter(app, "")
        expectHeader(app, "40 events", "back on the list")

        // More: Copy as JSON Lines, then Clear.
        let more = app.buttons["chat.inspector.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        attach(app, "6-more-menu")
        let copy = app.buttons["Copy as JSON Lines"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5) && copy.isEnabled, "Copy as JSON Lines is offered with rows")
        copy.tap()
        more.tap()
        let clear = app.buttons["Clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(app.staticTexts["No events yet"].waitForExistence(timeout: 10), "Clear empties the list\n\(app.debugDescription)")
        expectHeader(app, "0 events", "after Clear")
        attach(app, "7-cleared")
    }

    @MainActor
    func testLiveRecordsShowAfterClear() {
        let app = launch(count: 10, live: 4)
        defer { app.terminate() }
        let more = app.buttons["chat.inspector.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["Clear"].firstMatch.tap()
        // Records arriving after Clear show at once (4 a second here).
        let rows = app.buttons.matching(identifier: "chat.inspector.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "a record after Clear shows\n\(app.debugDescription)")
        let label = header(app).label
        XCTAssertTrue(label.hasSuffix(" events") && !label.contains("dropped"), "the header counts the new records, got '\(label)'")
        attach(app, "live-after-clear")
    }

    @MainActor
    func testEmptyJournalSaysNoEventsYet() {
        let app = launch(count: 0)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["No events yet"].waitForExistence(timeout: 10), "an empty journal\n\(app.debugDescription)")
        attach(app, "empty")
    }

    @MainActor
    func testOverflowSaysOlderDropped() {
        let app = launch(count: 501)
        defer { app.terminate() }
        expectHeader(app, "500 events · 1 older dropped", "500 records, then one more")
        attach(app, "dropped")
    }

    @MainActor
    func testChatWithoutJournalSaysNoEventsForThisChat() {
        let app = launch(count: -1)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["No events for this chat"].waitForExistence(timeout: 10), "no journal\n\(app.debugDescription)")
        attach(app, "no-journal")
    }
}

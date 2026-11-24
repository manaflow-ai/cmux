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
    private func launch(count: Int, live: Double? = nil, edge: String? = nil, after: Double? = nil) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "inspector"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "\(count)"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        if let live { app.launchEnvironment["CMUX_MOBILE_LIST_LIVE_HZ"] = "\(live)" }
        if let edge { app.launchEnvironment["CMUX_MOBILE_LIST_EDGE"] = edge }
        if let after { app.launchEnvironment["CMUX_MOBILE_LIST_EDGE_AFTER"] = "\(after)" }
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
    func testRowsFilterAndDetail() {
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
    }

    /// More (Copy as JSON Lines, then Clear), in its own launch: an active search hides the
    /// navigation bar on iOS 26, and More with it.
    @MainActor
    func testMoreCopyAndClear() {
        let app = launch(count: 40)
        defer { app.terminate() }
        expectHeader(app, "40 events", "a 40-record journal")
        let more = app.buttons["chat.inspector.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "More shows\n\(app.debugDescription)")
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

    /// The row "… · seq N" (its label is the title, then "dir · kind · time").
    @MainActor
    private func row(_ app: XCUIApplication, seq: Int) -> XCUIElement {
        app.buttons.matching(identifier: "chat.inspector.row").matching(NSPredicate(format: "label CONTAINS %@", "· seq \(seq),")).firstMatch
    }

    /// Scrolls to the list's end, where the oldest records are.
    @MainActor
    private func scrollToOldest(_ app: XCUIApplication) {
        let oldest = row(app, seq: 1)
        // Looked up every few flings: a lookup over the list costs about as much as a fling.
        for _ in 0..<40 where !(oldest.exists && oldest.isHittable) {
            for _ in 0..<4 { app.swipeUp(velocity: .fast) }
        }
        for _ in 0..<6 where !oldest.isHittable { app.swipeUp() }
        XCTAssertTrue(oldest.isHittable, "the oldest record is reached\n\(app.debugDescription)")
    }

    /// The "N new events" pill (EVT-14 amended, cmux#13742): its count, then a tap that lands
    /// the held records and shows the newest at the top.
    @MainActor
    private func pill(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["chat.inspector.newEvents"].firstMatch
    }

    @MainActor
    private func tapPillToTheNewest(_ app: XCUIApplication, newest seq: Int) {
        pill(app).tap()
        XCTAssertTrue(row(app, seq: seq).waitForExistence(timeout: 10) && pill(app).waitForNonExistence(timeout: 10),
                      "the pill lands the held records and shows the newest (seq \(seq))\n\(app.debugDescription)")
    }

    /// EVT-14 (amended, pending Aziz): the reader at the oldest records when 60 more arrive over
    /// the 500 cap. Away from the top the list holds still: the rows under the reader stay (their
    /// records dropped, their rows kept) and a pill counts the new ones. The pill lands them: the
    /// list then ends at the dropped rows' neighbour (seq 61), and the header says so.
    @MainActor
    func testRecordsDroppedUnderTheReader() {
        let app = launch(count: 500, edge: "drop", after: 150)
        defer { app.terminate() }
        expectHeader(app, "500 events", "a full journal")
        scrollToOldest(app)
        attach(app, "1-reader-at-oldest")
        XCTAssertTrue(pill(app).waitForExistence(timeout: 170), "the new records wait behind the pill\n\(app.debugDescription)")
        let sixty = NSPredicate(format: "label == %@", "60 new events")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: sixty, object: pill(app))], timeout: 10), .completed,
                       "the pill says exactly the 60 that came: '\(pill(app).label)'")
        XCTAssertTrue(row(app, seq: 1).isHittable, "the row under the reader stays while they read")
        attach(app, "2-held-pill")
        tapPillToTheNewest(app, newest: 560)
        for _ in 0..<3 where !header(app).exists { app.swipeDown() }
        expectHeader(app, "500 events · 60 older dropped", "the header counts the dropped")
        attach(app, "3-newest-after-pill")
        let neighbour = row(app, seq: 61)
        for _ in 0..<40 where !(neighbour.exists && neighbour.isHittable) {
            for _ in 0..<4 { app.swipeUp(velocity: .fast) }
        }
        for _ in 0..<6 where !neighbour.isHittable { app.swipeUp() }
        XCTAssertTrue(neighbour.isHittable, "the list ends at the dropped rows' neighbour\n\(app.debugDescription)")
        XCTAssertFalse(row(app, seq: 60).exists, "seq 60 dropped")
        XCTAssertFalse(row(app, seq: 1).exists, "seq 1 dropped")
        attach(app, "4-end-after-drop")
    }

    /// EVT-14: a record's detail stays open, showing it, when the record drops from the journal;
    /// back on the held list its row is still there, and opened again it says it was dropped.
    @MainActor
    func testDetailOfADroppedRecordKeepsShowingIt() {
        let app = launch(count: 500, edge: "drop", after: 150)
        defer { app.terminate() }
        scrollToOldest(app)
        row(app, seq: 1).tap()
        let json = app.descendants(matching: .any)["chat.inspector.json"].firstMatch
        XCTAssertTrue(json.waitForExistence(timeout: 10), "the detail opens\n\(app.debugDescription)")
        attach(app, "1-detail")
        // The drop lands while the detail is open (150 s after launch).
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(json.exists, "the detail stays")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: json)], timeout: 170)
        XCTAssertTrue(json.exists, "the detail still shows its record after it dropped\n\(app.debugDescription)")
        XCTAssertTrue(app.navigationBars.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "seq 1")).firstMatch.exists,
                      "the title is still the dropped record's")
        attach(app, "2-detail-after-drop")
        back.tap()
        XCTAssertTrue(pill(app).waitForExistence(timeout: 10), "back on the held list, the pill counts the new records\n\(app.debugDescription)")
        XCTAssertTrue(row(app, seq: 1).exists, "the dropped record's row is still where the reader left it")
        attach(app, "3-held-list")
        row(app, seq: 1).tap()
        XCTAssertTrue(json.waitForExistence(timeout: 10), "its detail opens\n\(app.debugDescription)")
        let note = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "dropped from the newest 500", "dropped from the newest 500")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: note, object: json)], timeout: 10), .completed,
                       "opened after the drop, the detail says the record was dropped\n\(app.debugDescription)")
        attach(app, "4-dropped-detail")
        back.tap()
        tapPillToTheNewest(app, newest: 560)
        attach(app, "5-newest-after-pill")
    }
}

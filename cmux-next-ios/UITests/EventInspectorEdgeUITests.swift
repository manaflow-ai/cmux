import XCTest

/// EVT-14 and EVT-15 (landscape): the Event Inspector at its edges, on the list rig's journal
/// (`CMUX_MOBILE_LIST_SCREEN=inspector`, ListStressChatScreens): exactly 1 record; one record over
/// the 256 KB cap (`LIST_GIANT=1`: kept as its kind and seq, with the note); the Mac gone mid-scroll
/// (`LIST_EDGE=offline`: no new rows, none lost); turning the iPhone keeps the row being read where
/// it was (a phone's screen stays portrait). Records dropped under the reader and a detail open on
/// a dropped record are EventInspectorUITests' (`LIST_EDGE=drop`).
final class EventInspectorEdgeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func launch(count: Int, live: Double? = nil, giant: Bool = false, edge: String? = nil) -> (XCUIApplication, XCUIElement) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "inspector"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "\(count)"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_SETTLE"] = "0"
        if let edge {
            app.launchEnvironment["CMUX_MOBILE_LIST_EDGE"] = edge
            app.launchEnvironment["CMUX_MOBILE_LIST_EDGE_AFTER"] = "8"
        }
        if let live { app.launchEnvironment["CMUX_MOBILE_LIST_LIVE_HZ"] = "\(live)" }
        if giant { app.launchEnvironment["CMUX_MOBILE_LIST_GIANT"] = "1" }
        // The rig's frame-interval windows (the burst's summary, `list.burst.frames`).
        app.launchEnvironment["CMUX_MOBILE_FRAMELOG"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Event Inspector"].waitForExistence(timeout: 40), "the inspector opens\n\(app.debugDescription)")
        let rows = app.buttons.matching(identifier: "chat.inspector.row")
        if count > 0 { XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "rows show\n\(app.debugDescription)") }
        return (app, app.windows.firstMatch)
    }

    @MainActor
    private func header(_ app: XCUIApplication) -> String {
        let element = app.staticTexts["chat.inspector.count"].firstMatch
        return element.exists ? element.label : ""
    }

    /// The row of record `seq` (its label has "seq N" followed by no digit).
    @MainActor
    private func seqRow(_ app: XCUIApplication, _ seq: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'chat.inspector.row' AND label MATCHES %@", "(?s).*seq \(seq)(\\D.*)?")).firstMatch
    }

    @MainActor
    func testExactlyOneRecord() {
        let (app, _) = launch(count: 1)
        defer { app.terminate() }
        XCTAssertEqual(app.buttons.matching(identifier: "chat.inspector.row").count, 1, "one row")
        XCTAssertTrue(header(app).hasPrefix("1 "), "the header counts one record, got '\(header(app))'")
        edgeShot(app, "evt14-one-record")
    }

    @MainActor
    func testRecordOverTheCapKeepsKindAndSeq() {
        let (app, _) = launch(count: 20, giant: true)
        defer { app.terminate() }
        let big = seqRow(app, 10)
        for _ in 0..<6 where !(big.exists && big.isHittable) { app.swipeUp() }
        XCTAssertTrue(big.exists && big.isHittable, "the oversized record is listed\n\(app.debugDescription)")
        edgeShot(app, "evt14-oversize-1-row")
        big.tap()
        let json = app.descendants(matching: .any)["chat.inspector.json"].firstMatch
        XCTAssertTrue(json.waitForExistence(timeout: 10), "its detail\n\(app.debugDescription)")
        let text = (json.value as? String ?? "") + json.label
        XCTAssertTrue(text.contains("only its kind and seq are kept on iPhone"), "the cut note, got \(text.prefix(300))")
        XCTAssertTrue(text.contains("\"seq\""), "its seq is kept, got \(text.prefix(300))")
        XCTAssertLessThan(text.count, 2000, "only the small kept record is shown (\(text.count) characters)")
        edgeShot(app, "evt14-oversize-2-detail")
    }

    @MainActor
    func testMacOfflineMidScrollAddsAndLosesNothing() {
        let (app, window) = launch(count: 40, live: 4, edge: "offline")
        defer { app.terminate() }
        // Online: records arrive (read at the top, where the count header is; it scrolls away with the list).
        let moving = header(app)
        let grows = NSPredicate { _, _ in self.header(app) != moving }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: grows, object: nil)], timeout: 6), .completed,
                       "records arrive while online ('\(moving)')")
        // Mid-scroll when the rig's Mac goes away, 8 s after the open.
        app.swipeUp()
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "the Mac goes away")], timeout: 10)
        let settled = RowFrames.settled(window, key: RowFrames.inspectorSeq)
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "nothing arrives")], timeout: 4)
        let later = RowFrames.read(window, key: RowFrames.inspectorSeq)
        XCTAssertEqual(Set(later.keys), Set(settled.keys), "the rows on screen stay")
        // Back at the top: the count holds still with the Mac gone, and scrolling loses nothing.
        for _ in 0..<6 where header(app).isEmpty { app.swipeDown() }
        let count = header(app)
        XCTAssertFalse(count.isEmpty, "the count header shows at the top\n\(app.debugDescription)")
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.header(app) != count }, object: nil)
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 4), .completed, "no new records once the Mac is gone ('\(count)' -> '\(header(app))')")
        app.swipeUp()
        for _ in 0..<6 where header(app).isEmpty { app.swipeDown() }
        XCTAssertEqual(header(app), count, "scrolling loses nothing")
        XCTAssertEqual(app.state, .runningForeground, "no crash")
        edgeNote("online from '\(moving)', offline '\(count)', rows \(settled.keys.sorted())", "evt14-offline")
        edgeShot(app, "evt14-offline")
    }

    /// EVT-7/EVT-12 (cmux#13742): a reader scrolled into the list when 2000 records arrive in
    /// a burst (about 40 a frame). The list holds still under them: the row being read moves at
    /// most 0.5 pt in every sample, through the burst and after it, though every record it shows
    /// drops from the journal. A pill counts the new records; tapped, it shows the newest.
    @MainActor
    func testABurstHoldsStillUnderAScrolledReader() throws {
        let (app, window) = launch(count: 500, edge: "burst")
        defer { app.terminate() }
        for _ in 0..<3 { app.swipeUp() }
        let before = RowFrames.settled(window, key: RowFrames.inspectorSeq)
        let reader = try XCTUnwrap(RowFrames.reader(before, in: window), "a row being read")
        var lines = ["reader \(reader) at \(before[reader]!)"]
        edgeShot(app, "burst-1-reader")
        let pill = app.buttons["chat.inspector.newEvents"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 20), "the burst's records wait behind the pill\n\(app.debugDescription)")
        // Through the burst (about a second) and after it.
        var worst: CGFloat = 0
        for sample in 0..<12 {
            let frames = RowFrames.read(window, key: RowFrames.inspectorSeq)
            let now = try XCTUnwrap(frames[reader], "the row being read stays on screen (sample \(sample))")
            worst = max(worst, abs(now.minY - before[reader]!.minY))
            lines.append("sample \(sample): \(now.minY - before[reader]!.minY) pt, pill '\(pill.exists ? pill.label : "")'")
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "the burst goes on")], timeout: 0.25)
        }
        edgeShot(app, "burst-2-held")
        edgeNote(lines.joined(separator: "\n"), "burst-frames")
        XCTAssertLessThanOrEqual(worst, RowFrames.shiftBar, "the row being read moved \(worst) pt during the burst")
        // The pill says the real count, past the journal's 500 as "500+" ("More than 500 new
        // events" to VoiceOver, its label here): 2000 came. Read once the burst has ended.
        let over = NSPredicate(format: "label == %@", "More than 500 new events")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: over, object: pill)], timeout: 10), .completed,
                       "the pill says more than 500 for the 2000 that came: '\(pill.label)'")
        edgeShot(app, "burst-3-pill-500plus")
        let said = pill.label
        pill.tap()
        let newest = seqRow(app, 2500)
        XCTAssertTrue(newest.waitForExistence(timeout: 10) && pill.waitForNonExistence(timeout: 10),
                      "the pill lands the burst and shows the newest record\n\(app.debugDescription)")
        edgeShot(app, "burst-4-newest")
        // What lands is the kept records; the header counts them and the ones the limit let go.
        for _ in 0..<4 where header(app).isEmpty { app.swipeDown() }
        let line = header(app)
        XCTAssertTrue(line.hasPrefix("500 events") && line.contains("older dropped"),
                      "the header counts the kept 500 and the dropped: '\(line)'\n\(app.debugDescription)")
        edgeNote("pill '\(said)', header '\(line)'", "burst-landed")
        edgeShot(app, "burst-5-header")
    }

    /// EVT-7 at the top (the common path: the inspector opens there): a reader at the top when
    /// 2000 records arrive in a burst sees them land live, once a frame, with no pill. The rig's
    /// frame-interval summary of the burst window (worst frame, hitch ms/s, main-thread CPU) is
    /// attached; no timing is asserted on an unleased host (ListPerfProfileUITests measures it
    /// under a lease).
    @MainActor
    func testABurstAtTheTopStaysSmooth() {
        let (app, _) = launch(count: 500, edge: "burst")
        defer { app.terminate() }
        let probe = app.staticTexts["list.burst.frames"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "the rig's burst probe\n\(app.debugDescription)")
        edgeShot(app, "burst-top-1-before")
        let done = NSPredicate(format: "label BEGINSWITH %@", "inspector-burst ")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: probe)], timeout: 40), .completed,
                       "the burst window ends ('\(probe.label)')")
        let summary = probe.label
        print("CMUX_INSPECTOR_BURST_TOP \(summary)")
        edgeNote(summary, "burst-top-frames")
        XCTAssertFalse(app.buttons["chat.inspector.newEvents"].exists, "at the top nothing is held: no pill")
        XCTAssertTrue(seqRow(app, 2500).waitForExistence(timeout: 10), "the newest record shows at the top\n\(app.debugDescription)")
        edgeShot(app, "burst-top-2-after")
    }

    /// EVT-15, landscape.
    @MainActor
    func testRotationKeepsTheRowBeingRead() throws {
        let (app, window) = launch(count: 40)
        defer { app.terminate() }
        app.swipeUp()
        let before = RowFrames.settled(window, key: RowFrames.inspectorSeq)
        let reader = try XCTUnwrap(RowFrames.reader(before, in: window), "a row being read")
        var lines = ["reader \(reader) at \(before[reader]!)", "window \(window.frame)"]
        edgeShot(app, "evt15-1-portrait")
        for (step, orientation) in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait].enumerated() {
            XCUIDevice.shared.orientation = orientation
            let frames = RowFrames.settled(window, key: RowFrames.inspectorSeq)
            let turned = window.frame
            edgeShot(app, "evt15-\(step + 2)-\(orientation == .portrait ? "portrait" : "landscape")")
            lines.append("step \(step) orientation \(orientation.rawValue): window \(turned), reader \(frames[reader].map { "\($0)" } ?? "off screen")")
            XCTAssertTrue(turned.width < turned.height, "a phone's screen stays portrait (window \(turned))")
            let now = try XCTUnwrap(frames[reader], "the row being read stays on screen at step \(step)")
            XCTAssertLessThanOrEqual(abs(now.minY - before[reader]!.minY), RowFrames.shiftBar,
                                     "the row being read moved \(now.minY - before[reader]!.minY) pt at step \(step)")
        }
        edgeNote(lines.joined(separator: "\n"), "evt15-frames")
    }
}

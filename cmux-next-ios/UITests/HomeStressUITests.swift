import XCTest

/// Home's list on the shared ``PagedList`` under a busy Mac while someone scrolls it (HOME-9,
/// verify/listperf/ `home-25-live`): 300 rows, 25 Chiefs typing and posting 20 times a second through
/// the Mac Home feed's own event and apply path (the list rig, `CMUX_MOBILE_LIST_SCREEN=home`).
///
/// Each speed keeps its measurement as `PAGEDLIST STRESS-down-<speed>-homelive` (the `ios-pagedlist`
/// bench's rows, judged by `scripts/ci/pagedlist_stress_gate.py --suite` this file) and fails when a
/// row being read moved in a frame the scroll does not explain (over half a point). Then: at the top a
/// Chief that posts slides in at the top of the rows; away from the top the newest pill counts it.
final class HomeStressUITests: XCTestCase {
    override func setUp() {
        // Every case is measured and recorded, also after an assertion fails.
        continueAfterFailure = true
    }

    @MainActor func testDownSlowHomeLive() { stress("down", .slow, "homelive") }
    @MainActor func testDownMediumHomeLive() { stress("down", .medium, "homelive") }
    @MainActor func testDownFastHomeLive() { stress("down", .fast, "homelive") }

    /// At the top, a Chief that posts slides in at the top of the rows (the list's spring, more than
    /// one frame); scrolled away, the newest pill counts the rows that arrived and its tap goes back.
    @MainActor
    func testNewMessageSlidesAtTopAndCountsAway() {
        let lab = launch(hz: 4)
        let name = "home-newest"
        lab.waitFor("a slide at the top", timeout: 30) { lab.reading.slides > 0 }
        lab.attach("\(name)-top")
        XCTAssertGreaterThan(lab.reading.slideFrames, 1, "\(name): the arrival jumped instead of sliding")
        for _ in 0..<4 { lab.scroll(towardOlder: true, direction: "down", speed: .fast) }
        let pill = lab.app.buttons["pagedList.newest"]
        XCTAssertTrue(pill.waitForExistence(timeout: 20), "\(name): no newest pill away from the top\n\(lab.app.debugDescription)")
        XCTAssertTrue(pill.label.hasSuffix(" new"), "\(name): the pill says \(pill.label)")
        lab.attach("\(name)-away")
        let slides = lab.reading.slides
        pill.tap()
        lab.waitFor("the jump back to the top", timeout: 10) { lab.reading.slides > slides }
        lab.attach("\(name)-back")
        lab.record("HOME-newest", lab.reading.json)
    }

    // MARK: The run

    @MainActor
    private func launch(hz: Int = 20) -> PagedLabDriver {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "home"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "300"
        app.launchEnvironment["CMUX_MOBILE_LIST_LIVE_HZ"] = String(hz)
        app.launchEnvironment["CMUX_MOBILE_LIST_LIVE_ROWS"] = "3"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_HUD"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        var lab = PagedLabDriver(app: app, test: self)
        lab.listID = "home.list"
        XCTAssertTrue(lab.list.waitForExistence(timeout: 30), "Home's list\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["lab.hud"].waitForExistence(timeout: 10), "the rig's measurement line")
        return lab
    }

    /// Scrolls down Home's rows and back under the live Mac, then keeps the measurement and judges it.
    @MainActor
    private func stress(_ direction: String, _ speed: PagedLabDriver.Speed, _ load: String) {
        let lab = launch()
        let name = "STRESS-\(direction)-\(speed.rawValue)-\(load)"
        XCTAssertTrue(lab.list.cells.firstMatch.waitForExistence(timeout: 20), "\(name): no rows")
        let gestures = speed == .slow ? 14 : 12
        for _ in 0..<gestures { lab.scroll(towardOlder: true, direction: direction, speed: speed) }
        lab.attach("\(name)-deep")
        for _ in 0..<(gestures / 2) { lab.scroll(towardOlder: false, direction: direction, speed: speed) }
        lab.settle(lab.list.cells.firstMatch)
        lab.attach("\(name)-back")
        let reading = lab.reading
        lab.record(name, #"{"direction":"\#(direction)","speed":"\#(speed.rawValue)","load":"\#(load)","window":null,"hud":\#(reading.json)}"#)
        XCTAssertEqual(lab.app.state, .runningForeground, "\(name): the app stopped")
        XCTAssertGreaterThan(reading.samples, 30, "\(name): the frame-shift measure sampled \(reading.samples) layout passes")
        XCTAssertGreaterThan(reading.changes, 0, "\(name): the live Mac changed nothing")
        XCTAssertLessThanOrEqual(reading.frameShift, 0.5,
                                 "\(name): a row being read moved \(reading.frameShift) pt in a frame the scroll does not explain (\(reading.shiftedFrames) frames)")
        XCTAssertLessThanOrEqual(reading.maxShift, 0.5, "\(name): a landing moved the reader \(reading.maxShift) pt")
    }
}

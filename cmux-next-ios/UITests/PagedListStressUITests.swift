import XCTest

/// The shared infinite-scroll list under load while someone scrolls it (verify/paged-list.md,
/// "Stress bench"): every direction (`down`, `up`) × scroll speed (`slow` held drags, `medium` short
/// flings, `fast` flings) × load (`flood`: rows arriving, edits, inserts, removals, moves, 1000-edit
/// bursts, failing and jittery pages; `edits`: 300 edits a second at the head, middle and tail, half
/// of them changing a row's height, with 2000-edit bursts; `inserts`: rows inserted mid-list,
/// removed and moved), plus a busy main thread and a 100,000-row list held in a 300-row window.
///
/// Each case keeps its measurement as `PAGEDLIST STRESS-<direction>-<speed>-<load>` (the
/// `ios-pagedlist` bench's rows) and fails when a row the reader was looking at moved in any frame
/// for a reason other than the scroll itself (`frameShift` over half a point), or when scrolling
/// hitched more than 10 ms a second (not with the busy main thread, which is measured, not judged).
final class PagedListStressUITests: XCTestCase {
    override func setUp() {
        // Every case is measured and recorded, also after an assertion fails.
        continueAfterFailure = true
    }

    // MARK: down × speed × load

    @MainActor func testDownSlowFlood() { stress("down", .slow, "flood") }
    @MainActor func testDownMediumFlood() { stress("down", .medium, "flood") }
    @MainActor func testDownFastFlood() { stress("down", .fast, "flood") }
    @MainActor func testDownSlowEdits() { stress("down", .slow, "edits") }
    @MainActor func testDownMediumEdits() { stress("down", .medium, "edits") }
    @MainActor func testDownFastEdits() { stress("down", .fast, "edits") }
    @MainActor func testDownSlowInserts() { stress("down", .slow, "inserts") }
    @MainActor func testDownMediumInserts() { stress("down", .medium, "inserts") }
    @MainActor func testDownFastInserts() { stress("down", .fast, "inserts") }

    // MARK: up × speed × load

    @MainActor func testUpSlowFlood() { stress("up", .slow, "flood") }
    @MainActor func testUpMediumFlood() { stress("up", .medium, "flood") }
    @MainActor func testUpFastFlood() { stress("up", .fast, "flood") }
    @MainActor func testUpSlowEdits() { stress("up", .slow, "edits") }
    @MainActor func testUpMediumEdits() { stress("up", .medium, "edits") }
    @MainActor func testUpFastEdits() { stress("up", .fast, "edits") }
    @MainActor func testUpSlowInserts() { stress("up", .slow, "inserts") }
    @MainActor func testUpMediumInserts() { stress("up", .medium, "inserts") }
    @MainActor func testUpFastInserts() { stress("up", .fast, "inserts") }

    // MARK: A busy main thread, and 100,000 rows in a window

    @MainActor func testDownFastBusy() { stress("down", .fast, "busy", judgeHitches: false) }
    @MainActor func testUpFastBusy() { stress("up", .fast, "busy", judgeHitches: false) }
    @MainActor func testDownFastHugeWindowed() { stress("down", .fast, "huge", window: 300) }
    @MainActor func testUpFastHugeWindowed() { stress("up", .fast, "huge", window: 300) }

    // MARK: The run

    /// Scrolls into the older pages and back toward the newest rows under `load`, then keeps the
    /// lab's measurement and judges it.
    @MainActor
    private func stress(_ direction: String, _ speed: PagedLabDriver.Speed, _ load: String,
                        window: Int? = nil, judgeHitches: Bool = true) {
        var extra = ["-cmux-mobile-paged-lab-stress", load]
        if let window { extra += ["-cmux-mobile-paged-lab-window", String(window)] }
        let lab = PagedLabDriver.launch("\(direction):normal", extra: extra, test: self)
        let name = "STRESS-\(direction)-\(speed.rawValue)-\(load)"
        // Any row: under a flood or inserts the first row read can already be off screen.
        XCTAssertTrue(lab.list.cells.firstMatch.waitForExistence(timeout: 20), "\(name): no rows")
        let gestures = speed == .slow ? 14 : 12
        for _ in 0..<gestures { lab.scroll(towardOlder: true, direction: direction, speed: speed) }
        lab.attach("\(name)-deep")
        for _ in 0..<(gestures / 2) { lab.scroll(towardOlder: false, direction: direction, speed: speed) }
        lab.settle(lab.list.cells.firstMatch)
        lab.attach("\(name)-back")
        let reading = lab.reading
        let windowJSON = window.map(String.init) ?? "null"
        lab.record(name, #"{"direction":"\#(direction)","speed":"\#(speed.rawValue)","load":"\#(load)","window":\#(windowJSON),"hud":\#(reading.json)}"#)
        XCTAssertEqual(lab.app.state, .runningForeground, "\(name): the app stopped")
        XCTAssertGreaterThan(reading.samples, 30, "\(name): the frame-shift measure sampled \(reading.samples) layout passes")
        XCTAssertGreaterThan(reading.changes, 0, "\(name): the load changed nothing")
        XCTAssertLessThanOrEqual(reading.frameShift, 0.5,
                                 "\(name): a row being read moved \(reading.frameShift) pt in a frame the scroll does not explain (\(reading.shiftedFrames) frames)")
        XCTAssertLessThanOrEqual(reading.maxShift, 0.5, "\(name): a landing page moved the reader \(reading.maxShift) pt")
        if judgeHitches {
            XCTAssertLessThanOrEqual(reading.hitchMsPerS, 10, "\(name): scrolling hitched \(reading.hitchMsPerS) ms a second")
        }
        if let window {
            XCTAssertLessThanOrEqual(reading.inMemory, window + 150, "\(name): \(reading.inMemory) row values in memory with a window of \(window)")
        }
    }
}

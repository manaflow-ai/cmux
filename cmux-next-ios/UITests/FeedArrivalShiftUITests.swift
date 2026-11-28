import CoreFoundation
import XCTest

/// FEED-15 (Aziz 2026-11-24, iPhone 16 Plus, 84 live Codex workspaces: "When a new feed row comes in as
/// I scroll there's a viewport shift"): while the reader drags, flings or rests away from the top,
/// rows arriving above never move the row being read. The app's DEBUG `FeedShiftProbe`
/// (`CMUX_MOBILE_FEED_SHIFT_PROBE=1`) reads the row being read every display frame against the scroll's
/// own movement, as PagedListStressUITests' shift bar: at most 0.5 pt in every frame, no shifted frame.
///
/// Each case names the mechanism it catches, so a failure says which fired:
/// - `Drag`, `Fling`: rows applied while UIKit moves the offset (a correction the gesture or the
///   deceleration undoes).
/// - `RestOffTop`: the apply-with-anchor at rest (a control: it held before the fix too).
/// - `RestJustBelowTop`: the old 60 pt "at top" band, where no anchor was kept. The list is placed
///   12 pt below the top by the probe (`CMUX_MOBILE_FEED_SHIFT_PLACE`): the short held drag that
///   placed it read as a hold on a row and opened it (green-43, feed15-red-7: "No matches found for Table").
/// - `HeaderOffTop`: a header re-measure off the top with no anchor (a refresh error comes and goes).
/// - `FingerResting`: a finger on the glass, not moving (tracking, offset still) while rows arrive
///   (a control: with no pan nothing undoes a correction, so it passes on 517b1e7f too).
/// - `RestAfterFling`: Aziz's recording (109.59 s: the pill went 102 -> 103 and every row moved down
///   one row, the list still): slow flings, and a row arrives as each deceleration's tail begins
///   (`CMUX_MOBILE_FEED_SHIFT_ARRIVE=tail`), when the list looks at rest but UIKit still moves it. It
///   fails on the probe's `rest=` count: rows that moved while the list looked still.
/// - `CreepingFinger`: a finger that comes down and creeps (half a drag's speed), with a row
///   arriving while it rests before its pan begins
///   (`CMUX_MOBILE_FEED_SHIFT_ARRIVE=touch`).
/// - `SettleFrame`: rows arriving as a deceleration ends, or just after (the settle frame): what
///   waited applies with its restore in one pass, never a frame with the rows shown before it.
/// - `HeaderDuringDrag`: the header changes height (a refresh error comes and goes every 0.5 s) while
///   the finger drags and while the list flings, mid-list.
/// - `OnScreenResize` (a guard: it passes on base too, SH-11 rule b): Show more on a row below the
///   first visible one. That row and the rows below it may move; the first row, above it, may not.
///
/// Not tested: an open ask resolving while it is the reader's anchor row (the next visible row must
/// stay within 0.5 pt); the rig has no way to answer an ask on screen yet.
///
/// Two loads: `feed-live` (the rig's 3 changes a second, one row in four) and `pressure84` (12 a
/// second: three rows a second, the rate of 84 workspaces with a row each about every 30 s).
/// Each case attaches the probe's reading with its notes (the last shifted frames and offsets set
/// while UIKit moved the list) and the list's trace (held, released, restore lines).
final class FeedArrivalShiftUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testDragFeedLive() { run(.drag, liveHz: 3) }
    @MainActor func testDragPressure84() { run(.drag, liveHz: 12) }
    @MainActor func testFlingFeedLive() { run(.fling, liveHz: 3) }
    @MainActor func testFlingPressure84() { run(.fling, liveHz: 12) }
    @MainActor func testRestOffTopFeedLive() { run(.restOffTop, liveHz: 3) }
    @MainActor func testRestOffTopPressure84() { run(.restOffTop, liveHz: 12) }
    @MainActor func testRestJustBelowTopPressure84() { run(.restJustBelowTop, liveHz: 12) }
    @MainActor func testHeaderOffTopFeedLive() { run(.headerOffTop, liveHz: 3) }
    @MainActor func testFingerRestingPressure84() { run(.fingerResting, liveHz: 12) }
    @MainActor func testRestAfterFlingPressure84() { run(.restAfterFling, liveHz: 12) }
    @MainActor func testCreepingFingerPressure84() { run(.creepingFinger, liveHz: 12) }
    @MainActor func testSettleFramePressure84() { run(.settleFrame, liveHz: 12) }
    @MainActor func testHeaderDuringDragFeedLive() { run(.headerDuringDrag, liveHz: 3) }
    @MainActor func testOnScreenResizeGuard() { run(.onScreenResize, liveHz: 0) }

    enum Case: String {
        case drag = "Drag (rows applied while the finger moves the list)"
        case fling = "Fling (rows applied while the list decelerates)"
        case restOffTop = "RestOffTop (apply with anchor at rest)"
        case restJustBelowTop = "RestJustBelowTop (the 60 pt at-top band, no anchor)"
        case headerOffTop = "HeaderOffTop (header re-measure off the top, no anchor)"
        case fingerResting = "FingerResting (a finger on the glass, not moving, while rows arrive)"
        case restAfterFling = "RestAfterFling (a row arrives as a fling settles, the list looking at rest)"
        case creepingFinger = "CreepingFinger (a finger rests, then creeps, while rows arrive)"
        case settleFrame = "SettleFrame (rows arriving as a deceleration ends)"
        case headerDuringDrag = "HeaderDuringDrag (the header changes height while the finger drags and the list flings)"
        case onScreenResize = "OnScreenResize guard (Show more below the first row: the first row stays)"
    }

    /// The app's load and measure start on this Darwin notification (FeedShiftProbe.startSignal),
    /// posted once the list is placed. Placing runs with no load: XCUITest waits for the app to go
    /// idle before each action, and a running load never lets it (feed15-red-2 c4876285 took 40-118 s
    /// to place the list). The measured gestures then run under load, driven as PagedLabDriver drives
    /// PagedListStressUITests' drags under inserts on the same fleet: XCUICoordinate
    /// press-and-drag for a held drag, swipeUp for a fling.
    static let startSignal = "dev.cmux.mobile.feed-shift.start"

    @MainActor
    private func run(_ which: Case, liveHz: Int) {
        let load = liveHz >= 12 ? "pressure84" : liveHz > 0 ? "feed-live" : "no-load"
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "300"
        if liveHz > 0 { app.launchEnvironment["CMUX_MOBILE_FEED_STRESS_LIVE"] = String(liveHz) }
        app.launchEnvironment["CMUX_MOBILE_FEED_SHIFT_PROBE"] = "1"
        if which == .headerOffTop { app.launchEnvironment["CMUX_MOBILE_FEED_STRESS_HEADER"] = "1.5" }
        if which == .headerDuringDrag { app.launchEnvironment["CMUX_MOBILE_FEED_STRESS_HEADER"] = "0.5" }
        if which == .restJustBelowTop { app.launchEnvironment["CMUX_MOBILE_FEED_SHIFT_PLACE"] = "12" }
        if which == .restAfterFling { app.launchEnvironment["CMUX_MOBILE_FEED_SHIFT_ARRIVE"] = "tail" }
        if which == .creepingFinger { app.launchEnvironment["CMUX_MOBILE_FEED_SHIFT_ARRIVE"] = "touch" }
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }
        _ = feedChipsAfterSetup(app)
        // Finished: no open asks pinned above the events, so the rig's new rows land on top, above the reader.
        app.buttons["Finished"].firstMatch.tap()
        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "\(which.rawValue): no Feed list")

        // Placing the list, before the load starts. RestJustBelowTop: the probe places it when the signal comes.
        if which != .restJustBelowTop {
            for _ in 0..<4 { app.swipeUp(velocity: .fast) }
        }
        // Placed: the load and the measure start, and the case's motion runs under them.
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(Self.startSignal as CFString), nil, nil, true)
        Thread.sleep(forTimeInterval: 1)
        switch which {
        case .drag:
            for _ in 0..<4 {
                let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -300)),
                           withVelocity: XCUIGestureVelocity(120), thenHoldForDuration: 0.4)
            }
        case .fling:
            for _ in 0..<4 {
                app.swipeUp(velocity: .fast)
                Thread.sleep(forTimeInterval: 1.2)
            }
        case .fingerResting:
            // Down and still for 8 s: the touch is held, the offset does not move.
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 8)
        case .restAfterFling:
            // Slow flings, each left to come to rest: the probe adds a row when the deceleration slows
            // under half a point a frame, so the pill's count rises while the list looks at rest.
            for _ in 0..<5 {
                app.swipeUp(velocity: .slow)
                Thread.sleep(forTimeInterval: 3)
            }
        case .creepingFinger:
            // Down for 0.15 s, then creeping 60 pt at 60 pt/s (its pan begins before a row's context
            // menu would open on a still finger), and held: the probe adds a row while the finger rests
            // before its pan begins, and the load adds more while it creeps.
            for _ in 0..<4 {
                let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                from.press(forDuration: 0.15, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -60)),
                           withVelocity: XCUIGestureVelocity(60), thenHoldForDuration: 0.6)
                Thread.sleep(forTimeInterval: 0.6)
            }
        case .settleFrame:
            // Short slow flings that come to rest every 0.7 s, under three rows a second: arrivals
            // land in and just after the frame each deceleration ends.
            for _ in 0..<10 {
                app.swipeUp(velocity: .slow)
                Thread.sleep(forTimeInterval: 0.7)
            }
        case .headerDuringDrag:
            for _ in 0..<3 {
                let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -300)),
                           withVelocity: XCUIGestureVelocity(120), thenHoldForDuration: 0.4)
            }
            for _ in 0..<3 {
                app.swipeUp(velocity: .fast)
                Thread.sleep(forTimeInterval: 1.2)
            }
        case .onScreenResize:
            // A Show more below the first visible row, both on screen.
            let first = list.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.'")).allElementsBoundByIndex
                .filter { $0.isHittable }.min { $0.frame.minY < $1.frame.minY }
            guard let first else { return XCTFail("\(which.rawValue): no row on screen") }
            let more = app.buttons.matching(NSPredicate(format: "label == 'Show more'")).allElementsBoundByIndex
                .filter { $0.isHittable && $0.frame.minY > first.frame.maxY }.min { $0.frame.minY < $1.frame.minY }
            guard let more else { return XCTFail("\(which.rawValue): no Show more below the first row on screen") }
            more.tap()
            Thread.sleep(forTimeInterval: 3)
            more.tap()
            Thread.sleep(forTimeInterval: 3)
        case .restOffTop, .restJustBelowTop, .headerOffTop:
            Thread.sleep(forTimeInterval: 10)
        }
        // At rest: what waited applies (FEED-15), and the measure sees it.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(list.exists, "\(which.rawValue) [\(load)]: the Feed list left the screen during the case")
        let reading = list.label
        let note = XCTAttachment(string: "\(which.rawValue), load \(load) (\(liveHz) changes/s): \(reading)")
        note.name = "feed15-\(load)-\(String(describing: which))"
        note.lifetime = .keepAlways
        add(note)
        let trace = XCTAttachment(string: (list.value as? String) ?? "")
        trace.name = "feed15-\(load)-\(String(describing: which))-trace"
        trace.lifetime = .keepAlways
        add(trace)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "feed15-\(load)-\(String(describing: which))-end"
        shot.lifetime = .keepAlways
        add(shot)
        let samples = Self.number("samples", in: reading)
        let shifted = Self.number("shifted", in: reading)
        let maxShift = Self.number("max", in: reading)
        let arrivals = Self.number("arrivals", in: reading)
        let rest = Self.number("rest", in: reading)
        let arrived = Self.number("arrived", in: reading)
        XCTAssertGreaterThan(samples, 30, "\(which.rawValue) [\(load)]: the shift measure judged \(samples) frames: \(reading)")
        if liveHz > 0 { XCTAssertGreaterThan(arrivals, 0, "\(which.rawValue) [\(load)]: no row arrived: \(reading)") }
        if which == .restAfterFling || which == .creepingFinger {
            XCTAssertGreaterThan(arrived, 0, "\(which.rawValue) [\(load)]: the probe never reached the case's moment (no row asked for): \(reading)")
        }
        if which == .restAfterFling {
            XCTAssertEqual(rest, 0, "FEED-15 \(which.rawValue) [\(load)]: rows moved in \(Int(rest)) frames while the list looked at rest (the recording's jump at 109.59 s): \(reading)")
        }
        XCTAssertTrue(maxShift <= 0.5 && shifted == 0,
                      "FEED-15 \(which.rawValue) [\(load)]: the row being read moved \(maxShift) pt in a frame the scroll does not explain, \(Int(shifted)) shifted frames: \(reading)")
    }

    /// `name=value` from the probe's reading.
    static func number(_ name: String, in reading: String) -> Double {
        guard let range = reading.range(of: "\(name)=") else { return -1 }
        let rest = reading[range.upperBound...]
        return Double(rest.prefix { "0123456789.".contains($0) }) ?? -1
    }
}

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
/// - `RestOffTop`: the apply-with-anchor at rest (the control: it held before the fix too).
/// - `RestJustBelowTop`: the old 60 pt "at top" band, where no anchor was kept.
/// - `HeaderOffTop`: a header re-measure off the top with no anchor (a refresh error comes and goes).
///
/// Two loads: `feed-live` (the rig's 3 changes a second, one row in four) and `pressure84` (12 a
/// second: three rows a second, the rate of 84 workspaces with a row each about every 30 s).
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

    enum Case: String {
        case drag = "Drag (rows applied while the finger moves the list)"
        case fling = "Fling (rows applied while the list decelerates)"
        case restOffTop = "RestOffTop (apply with anchor at rest)"
        case restJustBelowTop = "RestJustBelowTop (the 60 pt at-top band, no anchor)"
        case headerOffTop = "HeaderOffTop (header re-measure off the top, no anchor)"
    }

    /// The rig's load starts this long after launch: the list is placed before rows arrive.
    static let liveDelay = 20.0

    @MainActor
    private func run(_ which: Case, liveHz: Int) {
        let load = liveHz >= 12 ? "pressure84" : "feed-live"
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "300"
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS_LIVE"] = String(liveHz)
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS_LIVE_DELAY"] = String(Self.liveDelay)
        app.launchEnvironment["CMUX_MOBILE_FEED_SHIFT_PROBE"] = "1"
        if which == .headerOffTop { app.launchEnvironment["CMUX_MOBILE_FEED_STRESS_HEADER"] = "1.5" }
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }
        let launched = Date()
        _ = feedChipsAfterSetup(app)
        // Finished: no open asks pinned above the events, so the rig's new rows land on top, above the reader.
        app.buttons["Finished"].firstMatch.tap()
        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), "\(which.rawValue): no Feed list")

        // Placing the list, before the load starts.
        switch which {
        case .restJustBelowTop:
            // A few points below the true top: a short slow drag with a hold, so it stops where it is.
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -30)),
                        withVelocity: XCUIGestureVelocity(60), thenHoldForDuration: 0.6)
        default:
            for _ in 0..<4 { app.swipeUp(velocity: .fast) }
        }
        let placed = Date().timeIntervalSince(launched)
        XCTAssertLessThan(placed, Self.liveDelay - 1, "\(which.rawValue): placing the list took \(placed) s, past the load's start")
        // The load starts; the case's motion runs under it.
        Thread.sleep(forTimeInterval: max(0, Self.liveDelay - placed) + 0.5)
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
        case .restOffTop, .restJustBelowTop, .headerOffTop:
            Thread.sleep(forTimeInterval: 10)
        }
        // At rest: what waited applies (FEED-15), and the measure sees it.
        Thread.sleep(forTimeInterval: 3)
        let reading = (list.label)
        let note = XCTAttachment(string: "\(which.rawValue), load \(load) (\(liveHz) changes/s): \(reading)")
        note.name = "feed15-\(load)-\(String(describing: which))"
        note.lifetime = .keepAlways
        add(note)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "feed15-\(load)-\(String(describing: which))-end"
        shot.lifetime = .keepAlways
        add(shot)
        let samples = Self.number("samples", in: reading)
        let shifted = Self.number("shifted", in: reading)
        let maxShift = Self.number("max", in: reading)
        let arrivals = Self.number("arrivals", in: reading)
        XCTAssertGreaterThan(samples, 30, "\(which.rawValue) [\(load)]: the shift measure judged \(samples) frames: \(reading)")
        XCTAssertGreaterThan(arrivals, 0, "\(which.rawValue) [\(load)]: no row arrived: \(reading)")
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

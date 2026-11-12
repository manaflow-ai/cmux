import XCTest

/// The bottom bar's swipe up into the tab grid follows the thumb 1:1, as
/// Safari's does (Leo, 2026-11-12: the transition "goes too fast. It
/// accelerates too fast."). Scripted drags on the bar with the DEBUG probe on
/// (`CMUX_TABS_GESTURE_PROBE=1`, TabsKit `TabsGestureProbe`): each display
/// frame records the thumb and where the page point that was under it is
/// drawn. Prints `CMUX_TABS_GESTURE <run> ...` (tracking error, frame times)
/// and `CMUX_TABS_GESTURE_RAW <run> <frames>` for plotting, and fails when
/// that point is more than 2 pt from the thumb while the thumb is down.
///
///   cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///     --arg test --arg ui=TabsGestureProbeUITests --arg video --artifact artifacts/ios-sim/evidence.zip
final class TabsGestureProbeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// A steady swipe up (300 pt at 400 pt/s), released while moving.
    @MainActor
    func testSwipeUpTracksTheThumb() throws {
        try measure(run: "swipe", hold: 0.05, up: 300, velocity: 400, holdAtEnd: 0)
    }

    /// Safari's press and hold on the URL bar, then the drag (600 ms hold,
    /// 300 pt at 300 pt/s), held still at the end and released at rest.
    @MainActor
    func testHoldThenDragTracksTheThumb() throws {
        try measure(run: "hold", hold: 0.6, up: 300, velocity: 300, holdAtEnd: 0.3)
    }

    /// A short slow drag (90 pt at 150 pt/s) released at rest: tracks, then
    /// returns to the page.
    @MainActor
    func testShortDragTracksTheThumb() throws {
        try measure(run: "short", hold: 0.05, up: 90, velocity: 150, holdAtEnd: 0.25)
    }

    @MainActor
    private func measure(run: String, hold: TimeInterval, up: CGFloat, velocity: CGFloat, holdAtEnd: TimeInterval) throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_TABS_GESTURE_PROBE"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()

        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        row.tap()

        let address = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Address, '")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 15), "address bar\n\(app.debugDescription)")
        let probe = app.descendants(matching: .any)["tabs.gestureProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "probe element (DEBUG build with the probe on)")
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "\(run)-before")

        let from = address.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = from.withOffset(CGVector(dx: 0, dy: -up))
        from.press(forDuration: hold, thenDragTo: to, withVelocity: XCUIGestureVelocity(velocity), thenHoldForDuration: holdAtEnd)

        let done = expectation(for: NSPredicate(format: "label == 'runs 1'"), evaluatedWith: probe)
        wait(for: [done], timeout: 10)
        attach(app, "\(run)-after")
        let raw = probe.value as? String ?? ""
        print("CMUX_TABS_GESTURE_RAW \(run) \(raw)")

        struct Frame { var t, fx, fy, hx, hy: Double; var lifted: Bool }
        let frames: [Frame] = raw.split(separator: ";").compactMap { row in
            let c = row.split(separator: ",").compactMap { Double($0) }
            return c.count == 6 ? Frame(t: c[0], fx: c[1], fy: c[2], hx: c[3], hy: c[4], lifted: c[5] != 0) : nil
        }
        XCTAssertGreaterThan(frames.count, 10, "probe frames")
        let down = frames.filter { !$0.lifted }
        let errors = down.map { hypot($0.hx - $0.fx, $0.hy - $0.fy) }.sorted()
        let gaps = zip(frames.dropFirst(), frames).map { ($0.t - $1.t) * 1000 }.sorted()
        func pct(_ a: [Double], _ p: Double) -> Double { a.isEmpty ? 0 : a[min(a.count - 1, Int(Double(a.count - 1) * p))] }
        let budget = gaps.isEmpty ? 16.67 : (pct(gaps, 0.5) < 12 ? 8.33 : 16.67)
        let over = gaps.filter { $0 > 2 * budget }.count
        // Settle: how long after the lift the held point stops moving (< 0.25 pt per frame).
        let after = frames.filter(\.lifted)
        var settle = 0.0
        if let lift = after.first?.t {
            for (a, b) in zip(after, after.dropFirst()) where hypot(b.hx - a.hx, b.hy - a.hy) >= 0.25 { settle = b.t - lift }
        }
        let line = String(format: "CMUX_TABS_GESTURE %@ frames=%d down=%d err_p50=%.2f err_p95=%.2f err_max=%.2f frame_budget=%.2f frame_p50=%.2f frame_p95=%.2f frame_max=%.2f over_2x=%d settle_ms=%.0f",
                          run, frames.count, down.count, pct(errors, 0.5), pct(errors, 0.95), errors.last ?? 0,
                          budget, pct(gaps, 0.5), pct(gaps, 0.95), gaps.last ?? 0, over, settle * 1000)
        print(line)
        let note = XCTAttachment(string: line + "\n" + raw.replacingOccurrences(of: ";", with: "\n"))
        note.name = "\(run)-frames"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertLessThanOrEqual(errors.last ?? .infinity, 2, "the page point under the thumb drifted from it")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

import XCTest

/// conn-quiet (cmux#43295; Leo, 2026-11-14: "i also want all our connectivity stuff to shut the
/// f*** up and load faster"): in the real app, Home's connection toast over kept rows says
/// nothing for an outage under the quiet bound (`QuietStatusGate.threshold`, 10 s) and still
/// speaks for one that lasts. Demo retry-home-failed: the Mac's read fails and is never retried, so
/// Home is not live for the whole run (the gated "Couldn't refresh" toast; an unreachable Mac speaks at
/// once by design, its link having already waited the bound in `LiveCoordinator`, see
/// QuietBannerTests). The test reads the screen at 5 s and at
/// 15 s after the kept rows show, saves both, and prints when the toast first appeared.
final class HomeQuietToastUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheToastWaitsTheQuietBoundThenSpeaks() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore",
                                "-cmux-mobile-demo", "retry-home-failed"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        let row = app.buttons["home.row.stress-5"]
        // Whichever comes first, the team chooser or the kept rows: a fixed wait for the chooser
        // would let the rows show unseen and start the clock late.
        let giveUp = Date().addingTimeInterval(30)
        while !row.exists, !choose.exists, Date() < giveUp {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if !row.exists, choose.exists { app.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "a kept Home row\n\(app.debugDescription)")
        // The demo sets the failed read in the same step that shows its kept rows: Home stopped
        // being live when they appeared.
        let shown = Date()
        let toast = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
            "Couldn't refresh", "Offline", "Reconnecting", "Can't connect")).firstMatch

        // Under the bound: an outage of about 5 s.
        let early = toast.waitForExistence(timeout: 5)
        let firstSeenEarly = early ? Date().timeIntervalSince(shown) : nil
        wait(until: shown.addingTimeInterval(5))
        let toastAt5s = toast.exists
        attach(app, String(format: "1-home-kept-rows-at-%.1fs-toast-%@", Date().timeIntervalSince(shown), toastAt5s ? "shown" : "none"))

        // Past the bound: an outage of about 15 s.
        var firstSeen = firstSeenEarly
        if firstSeen == nil, toast.waitForExistence(timeout: max(0.1, 15 - Date().timeIntervalSince(shown))) {
            firstSeen = Date().timeIntervalSince(shown)
        }
        wait(until: shown.addingTimeInterval(15))
        let toastAt15s = toast.exists
        attach(app, String(format: "2-home-kept-rows-at-%.1fs-toast-%@", Date().timeIntervalSince(shown), toastAt15s ? "shown" : "none"))

        let line = String(format: "QUIET-TOAST toast_at_5s=%@ toast_at_15s=%@ first_seen_s=%@",
                          toastAt5s ? "yes" : "no", toastAt15s ? "yes" : "no",
                          firstSeen.map { String(format: "%.1f", $0) } ?? "never")
        print(line)
        let note = XCTAttachment(string: line + "\n")
        note.name = "home-quiet-toast.txt"
        note.lifetime = .keepAlways
        add(note)

        XCTAssertFalse(toastAt5s, "no connection toast over kept rows 5 s into an outage: \(line)")
        XCTAssertTrue(toastAt15s, "the toast speaks once the outage passes 10 s: \(line)")
        if let firstSeen { XCTAssertGreaterThanOrEqual(firstSeen, 9, "it waited the bound: \(line)") }
        XCTAssertTrue(row.exists, "the kept rows stay")
    }

    @MainActor
    private func wait(until deadline: Date) {
        let left = deadline.timeIntervalSinceNow
        if left > 0 { RunLoop.current.run(until: deadline) }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

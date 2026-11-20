import XCTest

/// The real app, both sides of the quiet bound (QuietStatusGate.threshold, 10 s; Leo,
/// 2026-11-14: "i also want all our connectivity stuff to shut the f*** up and load faster"):
/// kept rows over a list that never comes say nothing at about 5 s and "Updating…" at about
/// 15 s, on Home (its capsule) and on Workspaces (its subtitle). Screenshots at both points;
/// one `ui-readback:` line per check with its time, for the PR's numbers.
final class HomeKeptUpdatingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    private func launch(_ demo: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-demo", demo]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons.element(boundBy: 0).tap() }
        return app
    }

    @MainActor
    func testHomeKeptRowsSayUpdatingOnlyPastTheBound() throws {
        let app = launch("retry-home-kept-slow")
        // The fixture seeds the kept rows 12 s after launch: absent now, so the clock below
        // starts within a poll of the instant they (and the gate) start.
        let row = app.buttons["home.row.stress-5"]
        XCTAssertFalse(row.exists, "the kept rows come after launch")
        XCTAssertTrue(row.waitForExistence(timeout: 40), "the kept rows\n\(app.debugDescription)")
        let shown = Date()
        let note = app.descendants(matching: .any)["home.note.updating"]
        check(app, note, at: 5, since: shown, expect: false, "home-1-kept-5s")
        check(app, note, at: 15, since: shown, expect: true, "home-2-kept-15s")
    }

    @MainActor
    func testWorkspacesRefreshSaysUpdatingOnlyPastTheBound() throws {
        let app = launch("retry-refresh-slow")
        // The fixture starts the endless refresh and opens Workspaces together, 12 s after
        // launch: its rows are absent now, so the clock starts with the refresh.
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertFalse(row.exists, "Workspaces opens after launch")
        XCTAssertTrue(row.waitForExistence(timeout: 40), "the Workspaces rows\n\(app.debugDescription)")
        let shown = Date()
        let subtitle = app.staticTexts["Updating…"]
        check(app, subtitle, at: 5, since: shown, expect: false, "workspaces-1-refresh-5s")
        check(app, subtitle, at: 15, since: shown, expect: true, "workspaces-2-refresh-15s")
    }

    @MainActor
    private func check(_ app: XCUIApplication, _ element: XCUIElement, at seconds: Double, since start: Date,
                       expect shows: Bool, _ name: String) {
        let wait = start.addingTimeInterval(seconds).timeIntervalSinceNow
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let exists = element.exists
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let line = "ui-readback: \(name) t=\(ms)ms updating=\(exists) expected=\(shows)"
        print(line)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let text = XCTAttachment(string: line)
        text.name = "\(name).txt"
        text.lifetime = .keepAlways
        add(text)
        XCTAssertEqual(exists, shows, line)
    }
}

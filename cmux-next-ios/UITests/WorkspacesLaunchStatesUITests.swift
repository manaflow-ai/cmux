import XCTest

/// CMUX-49: the Workspaces page's launch states on mock data, one indicator at
/// a time. A first launch says what it loads (and never "Updating…" over the
/// placeholders), an offline one says it waits for a connection, a failed one
/// says why with Retry, and a cached list whose refresh failed keeps its rows.
final class WorkspacesLaunchStatesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ demo: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore",
                                "-cmux-mobile-demo", demo]
        app.launch()
        return app
    }

    private func text(_ app: XCUIApplication, containing value: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    @MainActor
    func testFirstLaunchSaysWhatItLoadsWithOneIndicator() {
        let app = launch("retry-first-launch")
        defer { app.terminate() }
        let loading = app.descendants(matching: .any)["workspaces.loading"]
        XCTAssertTrue(loading.waitForExistence(timeout: 30), "first-launch placeholders\n\(app.debugDescription)")
        XCTAssertTrue(text(app, containing: "Loading workspaces").waitForExistence(timeout: 5),
                      "the placeholders say what loads\n\(app.debugDescription)")
        // Past the 1.5 s "Updating…" delay: the title must not stack a second indicator.
        XCTAssertFalse(text(app, containing: "Updating").waitForExistence(timeout: 3), "no stacked Updating…")
        XCTAssertFalse(app.descendants(matching: .any)["workspaces.empty.all"].exists, "no empty claim while loading")
        XCTAssertFalse(text(app, containing: "Connect a Mac").exists, "no connect-a-Mac claim while loading")
        attach(app, "first-launch")
    }

    @MainActor
    func testFirstLaunchOfflineSaysItWaits() {
        let app = launch("retry-first-launch-offline")
        defer { app.terminate() }
        XCTAssertTrue(text(app, containing: "Waiting for a connection").waitForExistence(timeout: 30),
                      "offline first launch\n\(app.debugDescription)")
        attach(app, "first-launch-offline")
    }

    @MainActor
    func testFailedFirstLaunchSaysWhyAndOffersRetry() {
        let app = launch("retry-first-launch-failed")
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["workspaces.retry"].waitForExistence(timeout: 30),
                      "failed first launch\n\(app.debugDescription)")
        XCTAssertTrue(text(app, containing: "This iPhone is offline").exists, "the reason\n\(app.debugDescription)")
        // Exactly one Retry: the offline pill is status only, the page offers the retry.
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Retry")).count, 1,
                       "one Retry on screen\n\(app.debugDescription)")
        attach(app, "first-launch-failed")
    }

    @MainActor
    func testFailedRefreshKeepsTheCachedRows() {
        let app = launch("retry-refresh-failed")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.row.")).firstMatch.waitForExistence(timeout: 30),
                      "cached rows stay\n\(app.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["workspaces.retry"].exists, "no error page over the rows")
        // No connection words over kept rows (iOS release bar read-back: "Couldn't refresh · last known").
        XCTAssertFalse(text(app, containing: "last known").waitForExistence(timeout: 3), "no stale-rows text\n\(app.debugDescription)")
        XCTAssertFalse(text(app, containing: "Couldn't refresh").exists, "no refresh-failed text\n\(app.debugDescription)")
        attach(app, "refresh-failed")
    }

    /// The first-load hand-off (#48907, #48947): the team loads, then the Macs' lists load, then
    /// the rows arrive (DemoDriver `retry-first-launch-handoff`, 2.5 s a phase). From the first
    /// placeholder row to the first workspace row, something is always on screen: a sample with
    /// neither is the blink those fixes removed. The step's video shows the same frames.
    @MainActor
    func testFirstLoadHandOffKeepsThePlaceholderRowsUntilTheRows() {
        let app = launch("retry-first-launch-handoff")
        defer { app.terminate() }
        let loading = app.descendants(matching: .any)["workspaces.loading"]
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.row."))
        XCTAssertTrue(loading.waitForExistence(timeout: 30), "first-load placeholders\n\(app.debugDescription)")
        attach(app, "handoff-first-load")
        let start = Date()
        var timeline: [String] = []
        var gaps: [String] = []
        var sawListPhase = false
        while Date().timeIntervalSince(start) < 20 {
            let t = Date().timeIntervalSince(start)
            let shown = loading.exists
            let listed = rows.firstMatch.exists
            timeline.append(String(format: "%.2f placeholder=%d rows=%d", t, shown ? 1 : 0, listed ? 1 : 0))
            if listed { break }
            if !shown { gaps.append(String(format: "%.2f s: no placeholder and no rows", t)) }
            if t > 3, !sawListPhase { sawListPhase = true; attach(app, "handoff-lists-loading") }
        }
        attach(app, "handoff-rows")
        let note = XCTAttachment(string: timeline.joined(separator: "\n"))
        note.name = "handoff-timeline"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertTrue(rows.firstMatch.exists, "the rows arrived\n\(timeline.joined(separator: "\n"))")
        XCTAssertGreaterThan(timeline.count, 10, "too few samples to see a blink")
        XCTAssertTrue(gaps.isEmpty, "the placeholder rows blinked out:\n\(gaps.joined(separator: "\n"))")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

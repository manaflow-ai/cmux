import XCTest

/// CMUX-49: the Workspaces page's launch states on mock data, one indicator at
/// a time. A first launch says what it loads (and never "Updating…" over the
/// placeholders), an offline one says it waits for a connection, a failed one
/// retries on its own and, past the quiet bound, says why (no Retry), and a cached list whose refresh failed keeps its rows.
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
        // Past 1.5 s (when the title once said "Updating…"): no second indicator.
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
    func testFailedFirstLaunchRetriesOnItsOwnThenSaysWhy() {
        let app = launch("retry-first-launch-failed")
        defer { app.terminate() }
        // Retried on its own: the placeholders first, the failure page only past the quiet bound (10 s).
        XCTAssertTrue(app.descendants(matching: .any)["workspaces.loading"].waitForExistence(timeout: 8),
                      "placeholders while it retries\n\(app.debugDescription)")
        XCTAssertTrue(app.descendants(matching: .any)["workspaces.loadFailed"].waitForExistence(timeout: 30),
                      "failed first launch\n\(app.debugDescription)")
        XCTAssertTrue(text(app, containing: "This iPhone is offline").exists, "the reason\n\(app.debugDescription)")
        // Nothing to decide: no Retry or Try Again anywhere on the page.
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label IN %@", ["Retry", "Try Again", "Try again"])).count, 0,
                       "no retry button on screen\n\(app.debugDescription)")
        attach(app, "first-launch-failed")
    }

    @MainActor
    func testFailedRefreshKeepsTheCachedRows() {
        let app = launch("retry-refresh-failed")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.row.")).firstMatch.waitForExistence(timeout: 30),
                      "cached rows stay\n\(app.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["workspaces.loadFailed"].exists, "no error page over the rows")
        // No connection words over kept rows (iOS release bar read-back: "Couldn't refresh · last known").
        XCTAssertFalse(text(app, containing: "last known").waitForExistence(timeout: 3), "no stale-rows text\n\(app.debugDescription)")
        XCTAssertFalse(text(app, containing: "Couldn't refresh").exists, "no refresh-failed text\n\(app.debugDescription)")
        attach(app, "refresh-failed")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

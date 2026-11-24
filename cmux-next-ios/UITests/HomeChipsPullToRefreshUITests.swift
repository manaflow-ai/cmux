import XCTest

/// The user, 2026-11-23: "why is there an updating spinner in the bottom when reconnecting already
/// exists at the top? seems redundant ... only reconnecting shows. Also the Chiefs list should have
/// swipe to refresh just like the Workspaces list does." Each state of Home's two chips, and its
/// pull to refresh (idle, pulled, refreshing, done), in light and in dark.
final class HomeChipsPullToRefreshUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .unspecified
    }

    @MainActor
    private func launch(_ demo: String, refreshSeconds: Double? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        if let refreshSeconds { app.launchEnvironment["CMUX_MOBILE_LIST_REFRESH_SECONDS"] = "\(refreshSeconds)" }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-demo", demo]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons.element(boundBy: 0).tap() }
        return app
    }

    private var updatingChip: (XCUIApplication) -> XCUIElement {
        { $0.descendants(matching: .any)["home.note.updating"] }
    }

    private func reconnectingChip(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Reconnecting")).firstMatch
    }

    private let appearances: [(XCUIDevice.Appearance, String)] = [(.light, "light"), (.dark, "dark")]

    /// Kept rows refreshing over a live link: "Updating" at the bottom, alone.
    @MainActor
    func testUpdatingAloneShowsAtTheBottom() throws {
        for (appearance, mode) in appearances {
            XCUIDevice.shared.appearance = appearance
            let app = launch("home-chip-updating")
            XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "kept rows\n\(app.debugDescription)")
            XCTAssertTrue(updatingChip(app).waitForExistence(timeout: 15), "the Updating chip\n\(app.debugDescription)")
            XCTAssertFalse(reconnectingChip(app).exists, "no Reconnecting")
            attach(app, "chips-updating-only-\(mode)")
            app.terminate()
        }
    }

    /// The user's screenshot: kept rows while a retry runs. Before, both chips showed; now only
    /// Reconnecting at the top.
    @MainActor
    func testReconnectingHidesUpdating() throws {
        for (appearance, mode) in appearances {
            XCUIDevice.shared.appearance = appearance
            let app = launch("home-chip-reconnecting")
            XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "kept rows\n\(app.debugDescription)")
            // A link chip waits its 10 s quiet bound before it shows.
            XCTAssertTrue(reconnectingChip(app).waitForExistence(timeout: 25), "Reconnecting\n\(app.debugDescription)")
            XCTAssertFalse(updatingChip(app).exists, "no Updating under Reconnecting\n\(app.debugDescription)")
            attach(app, "chips-both-now-reconnecting-only-\(mode)")
            app.terminate()
        }
    }

    /// A retry over a live list (nothing kept to update): Reconnecting alone.
    @MainActor
    func testReconnectingAlone() throws {
        for (appearance, mode) in appearances {
            XCUIDevice.shared.appearance = appearance
            let app = launch("home-chip-reconnecting-live")
            XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "rows\n\(app.debugDescription)")
            XCTAssertTrue(reconnectingChip(app).waitForExistence(timeout: 25), "Reconnecting\n\(app.debugDescription)")
            XCTAssertFalse(updatingChip(app).exists, "no Updating")
            attach(app, "chips-reconnecting-only-\(mode)")
            app.terminate()
        }
    }

    /// A live list: neither chip.
    @MainActor
    func testNeitherChip() throws {
        for (appearance, mode) in appearances {
            XCUIDevice.shared.appearance = appearance
            let app = launch("home-chip-neither")
            XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "rows\n\(app.debugDescription)")
            _ = reconnectingChip(app).waitForExistence(timeout: 12)
            XCTAssertFalse(reconnectingChip(app).exists, "no Reconnecting")
            XCTAssertFalse(updatingChip(app).exists, "no Updating")
            attach(app, "chips-neither-\(mode)")
            app.terminate()
        }
    }

    /// Workspaces' pull to refresh on the Chiefs list: idle, a short pull that springs back,
    /// a full pull that refreshes (the wheel in its slot under the search field), then done.
    @MainActor
    func testPullToRefresh() throws {
        for (appearance, mode) in appearances {
            XCUIDevice.shared.appearance = appearance
            let app = launch("home-chip-neither", refreshSeconds: 4)
            let first = app.buttons["home.row.stress-4"]
            XCTAssertTrue(first.waitForExistence(timeout: 30), "rows\n\(app.debugDescription)")
            sleep(1)
            attach(app, "ptr-1-idle-\(mode)")
            let top = first.frame.minY
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: top + 20))
            // A short pull: the ticks fill in but it never refreshes, and the list springs back.
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 110)),
                        withVelocity: .slow, thenHoldForDuration: 0.6)
            sleep(1)
            XCTAssertEqual(first.frame.minY, top, accuracy: 2, "a short pull springs back")
            // A full pull: past 186 pt the wheel spins in its slot while the refresh runs.
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
            attach(app, "ptr-2-refreshing-\(mode)")
            XCTAssertGreaterThan(first.frame.minY, top + 40, "the rows sit under the refresh slot\n\(app.debugDescription)")
            // Done (4 s): the slot closes and the rows settle back where they were.
            sleep(6)
            XCTAssertEqual(first.frame.minY, top, accuracy: 2, "the slot closed\n\(app.debugDescription)")
            attach(app, "ptr-3-done-\(mode)")
            app.terminate()
        }
    }

    /// A pull while kept rows update: the wheel speaks, so the Updating chip goes for the pull.
    @MainActor
    func testPullHidesUpdatingWhileItRuns() throws {
        XCUIDevice.shared.appearance = .light
        let app = launch("home-chip-updating", refreshSeconds: 4)
        let first = app.buttons["home.row.stress-4"]
        XCTAssertTrue(first.waitForExistence(timeout: 30), "rows\n\(app.debugDescription)")
        XCTAssertTrue(updatingChip(app).waitForExistence(timeout: 15), "Updating first")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: first.frame.minY + 20))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(updatingChip(app).waitForNonExistence(timeout: 3), "no Updating during the pull\n\(app.debugDescription)")
        attach(app, "ptr-updating-hidden-during-pull-light")
        app.terminate()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

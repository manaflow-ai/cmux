import XCTest

/// The user, 2026-11-23: "why is there an updating spinner in the bottom when reconnecting already
/// exists at the top? seems redundant ... only reconnecting shows. Also the Chiefs list should have
/// swipe to refresh just like the Workspaces list does." Each state of Home's two chips, and its
/// pull to refresh (idle, pulled, refreshing, done), in light and in dark.
final class HomeChipsPullToRefreshUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ demo: String, mode: String = "light", refreshSeconds: Double? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        // The app's own Appearance setting (Settings > Appearance), which overrides the system's.
        app.launchArguments += ["-cmuxMobile.settings.appearance", mode]
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

    private let modes = ["light", "dark"]

    /// A connection chip is drawn see-through for its 10 s quiet bound (``QuietStatusGate``) before
    /// it shows; the shots wait it out.
    private func waitOutQuietBound() { sleep(12) }

    /// Kept rows refreshing over a live link: "Updating" at the bottom, alone.
    @MainActor
    func testUpdatingAloneShowsAtTheBottom() throws {
        for mode in modes {
            let app = launch("home-chip-updating", mode: mode)
            XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "kept rows\n\(app.debugDescription)")
            XCTAssertTrue(updatingChip(app).waitForExistence(timeout: 15), "the Updating chip\n\(app.debugDescription)")
            XCTAssertFalse(reconnectingChip(app).exists, "no Reconnecting")
            waitOutQuietBound()
            attach(app, "chips-updating-only-\(mode)")
            app.terminate()
        }
    }

    /// The user's screenshot: kept rows while a retry runs. Before, both chips showed; now only
    /// Reconnecting at the top.
    @MainActor
    func testReconnectingHidesUpdating() throws {
        for mode in modes {
            let app = launch("home-chip-reconnecting", mode: mode)
            XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "kept rows\n\(app.debugDescription)")
            // A link chip waits its 10 s quiet bound before it shows.
            XCTAssertTrue(reconnectingChip(app).waitForExistence(timeout: 25), "Reconnecting\n\(app.debugDescription)")
            XCTAssertFalse(updatingChip(app).exists, "no Updating under Reconnecting\n\(app.debugDescription)")
            waitOutQuietBound()
            attach(app, "chips-both-now-reconnecting-only-\(mode)")
            app.terminate()
        }
    }

    /// A retry over a live list (nothing kept to update): Reconnecting alone.
    @MainActor
    func testReconnectingAlone() throws {
        for mode in modes {
            let app = launch("home-chip-reconnecting-live", mode: mode)
            XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "rows\n\(app.debugDescription)")
            XCTAssertTrue(reconnectingChip(app).waitForExistence(timeout: 25), "Reconnecting\n\(app.debugDescription)")
            XCTAssertFalse(updatingChip(app).exists, "no Updating")
            waitOutQuietBound()
            attach(app, "chips-reconnecting-only-\(mode)")
            app.terminate()
        }
    }

    /// A live list: neither chip.
    @MainActor
    func testNeitherChip() throws {
        for mode in modes {
            let app = launch("home-chip-neither", mode: mode)
            XCTAssertTrue(app.buttons["home.row.stress-5"].waitForExistence(timeout: 30), "rows\n\(app.debugDescription)")
            _ = reconnectingChip(app).waitForExistence(timeout: 12)
            XCTAssertFalse(reconnectingChip(app).exists, "no Reconnecting")
            XCTAssertFalse(updatingChip(app).exists, "no Updating")
            waitOutQuietBound()
            attach(app, "chips-neither-\(mode)")
            app.terminate()
        }
    }

    /// Workspaces' pull to refresh on the Chiefs list: idle, a short pull that springs back,
    /// a full pull that refreshes (the wheel in its slot under the search field), then done.
    @MainActor
    func testPullToRefresh() throws {
        for mode in modes {
            let app = launch("home-chip-neither", mode: mode, refreshSeconds: 4)
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
            // The pull also opens the search drawer above the list (as on Workspaces), which stays.
            let rest = first.frame.minY
            XCTAssertLessThan(rest - top, 80, "a short pull never refreshes: at most the search drawer opened")
            attach(app, "ptr-1b-after-short-pull-\(mode)")
            // A full pull: past 186 pt the wheel spins in its slot while the refresh runs.
            // A full pull, top of the list to the bottom of the screen: UIKit's rubber band turns
            // it into the 186 pt that starts a refresh (420 pt of drag gives only about 180 pt).
            fullPull(app)
            attach(app, "ptr-2-refreshing-\(mode)")
            XCTAssertGreaterThan(first.frame.minY, rest + 40, "the rows sit under the refresh slot; \(readout(app))")
            // Done (4 s): the slot closes and the rows settle back where they were.
            sleep(6)
            // The slot closed: the rows rest under the search field, or at the list's top
            // with the search drawer tucked away again.
            XCTAssertTrue(abs(first.frame.minY - rest) < 2 || abs(first.frame.minY - top) < 2, "the slot closed (\(first.frame.minY)); \(readout(app))")
            attach(app, "ptr-3-done-\(mode)")
            app.terminate()
        }
    }

    /// A pull while kept rows update: the wheel speaks, so the Updating chip goes for the pull.
    @MainActor
    func testPullHidesUpdatingWhileItRuns() throws {
        let app = launch("home-chip-updating", refreshSeconds: 4)
        let first = app.buttons["home.row.stress-4"]
        XCTAssertTrue(first.waitForExistence(timeout: 30), "rows\n\(app.debugDescription)")
        XCTAssertTrue(updatingChip(app).waitForExistence(timeout: 15), "Updating first")
        waitOutQuietBound()
        attach(app, "ptr-updating-before-pull-light")
        fullPull(app)
        XCTAssertTrue(updatingChip(app).waitForNonExistence(timeout: 3), "no Updating during the pull; \(readout(app))")
        attach(app, "ptr-updating-hidden-during-pull-light")
        app.terminate()
    }

    /// The pull control's own state (DEBUG, with the rig's refresh): attached, furthest pull, refreshes.
    @MainActor
    private func readout(_ app: XCUIApplication) -> String {
        let element = app.descendants(matching: .any)["list.pullToRefresh.readout"]
        return element.exists ? "readout: \(element.value as? String ?? "?")" : "readout: missing (the probe never found the list)"
    }

    /// From the top of the list to the bottom of the screen, slowly, then let go.
    @MainActor
    private func fullPull(_ app: XCUIApplication) {
        // In the list (the pinned grid's gap between tiles), not on the bars: a drag that starts
        // on the toolbar or the search field barely moves the list.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.25))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.995))
        top.press(forDuration: 0.1, thenDragTo: bottom, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

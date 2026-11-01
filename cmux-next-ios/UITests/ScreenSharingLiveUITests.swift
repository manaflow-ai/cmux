import XCTest

/// Screen Sharing end to end, live (verify/screen-sharing.md): this simulator
/// signs in as the test account, opens Settings > Screen Sharing, connects to
/// a real Mac through the device hub, and controls it. The Mac runs
/// InputProbe (verify/screen-sharing/InputProbe.swift), which shows every
/// event it receives, so each step's screenshot shows the Mac's side too.
///
/// Runs only when the rig sets the test runner's environment
/// (`TEST_RUNNER_CMUX_SS_LIVE=1`, `TEST_RUNNER_CMUX_SS_MAC=<Mac name>`,
/// `TEST_RUNNER_CMUX_SS_EMAIL`, `TEST_RUNNER_CMUX_SS_PASSWORD`); the Mac's
/// person (or the rig) answers the Allow prompt.
final class ScreenSharingLiveUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    var environment: [String: String] { ProcessInfo.processInfo.environment }

    @MainActor
    func testSeeAndControlAMac() throws {
        guard environment["CMUX_SS_LIVE"] == "1", let mac = environment["CMUX_SS_MAC"],
              let email = environment["CMUX_SS_EMAIL"], let password = environment["CMUX_SS_PASSWORD"] else {
            throw XCTSkip("live rig only (TEST_RUNNER_CMUX_SS_LIVE)")
        }
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_STACK_EMAIL"] = email
        app.launchEnvironment["CMUX_MOBILE_STACK_PASSWORD"] = password
        if let hub = environment["CMUX_SS_HUB"] { app.launchEnvironment["CMUX_MOBILE_DEVICE_HUB_URL"] = hub }
        app.launchArguments += ["-cmux-mobile-no-restore"]
        app.launch()
        passSetup(app)
        attach(app, "01-signed-in")

        // Settings > Screen Sharing.
        app.tabBars.buttons["Settings"].tap()
        let row = app.buttons["settings.screenSharing"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Screen Sharing row\n\(app.debugDescription)")
        row.tap()
        let macRow = app.buttons["screenSharing.mac.\(mac)"].firstMatch
        XCTAssertTrue(macRow.waitForExistence(timeout: 60), "Mac row \(mac)\n\(app.debugDescription)")
        XCTAssertTrue(wait(for: macRow, enabled: true, timeout: 60), "Mac \(mac) not shared/online\n\(app.debugDescription)")
        attach(app, "02-screen-sharing-page")

        macRow.tap()
        attach(app, "03-requested")
        // The stats line ("… fps …") shows once frames arrive: after the Mac's Allow and the WebRTC handshake.
        // By identifier: a predicate over every text times out while the screen redraws at 30-60 fps.
        let stats = app.staticTexts["screen.stats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 180), "stream never started\n\(app.debugDescription)")
        settle(app, 3)
        attach(app, "04-streaming-portrait")

        let screen = app.scrollViews["screen.view"]
        XCTAssertTrue(screen.waitForExistence(timeout: 10), "screen view\n\(app.debugDescription)")
        let center = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))

        // Direct touch: tap = click, double tap = double click, two-finger tap = right click.
        center.tap()
        settle(app, 1.5)
        attach(app, "05-tap-click")
        center.doubleTap()
        settle(app, 1.5)
        attach(app, "06-double-click")
        screen.twoFingerTap()
        settle(app, 1.5)
        attach(app, "07-two-finger-right-click")
        // Press and hold, then drag: a left drag.
        center.press(forDuration: 0.8, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.57)))
        settle(app, 1.5)
        attach(app, "08-hold-drag")

        // Keyboard: type into the Mac.
        let keyboardButton = app.buttons["Keyboard"].firstMatch
        if keyboardButton.waitForExistence(timeout: 5) {
            keyboardButton.tap()
            settle(app, 1)
            // The screen's key target is a plain UIKeyInput view XCUITest can't focus: type on the system keyboard.
            for key in ["h", "e", "l", "l", "o"] where app.keyboards.keys[key].waitForExistence(timeout: 5) {
                app.keyboards.keys[key].tap()
            }
            settle(app, 1.5)
            attach(app, "09-typed")
            // Sticky ⌘ from the keyboard bar, then a tap: a ⌘-click on the Mac.
            let command = app.buttons["⌘ modifier"]
            if command.waitForExistence(timeout: 5) {
                command.tap()
                keyboardButton.tap()
                settle(app, 1)
                center.tap()
                settle(app, 1.5)
                attach(app, "10-command-click")
            } else {
                keyboardButton.tap()
            }
        }

        // Trackpad mode (Options › Input): one finger moves the pointer, a tap clicks where it is.
        app.buttons["screen.options"].tap()
        let input = app.buttons["Input"].firstMatch
        if input.waitForExistence(timeout: 5) {
            input.tap()
            app.buttons["Trackpad"].firstMatch.tap()
            settle(app, 1)
            screen.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.55))
                .press(forDuration: 0.05, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.56)))
            settle(app, 1)
            center.tap()
            settle(app, 1.5)
            attach(app, "10b-trackpad-move-and-tap")
            // The menu's on/off items: Stream stats off hides the stats line, on brings it back.
            app.buttons["screen.options"].tap()
            if app.buttons["Stream stats"].firstMatch.waitForExistence(timeout: 5) {
                app.buttons["Stream stats"].firstMatch.tap()
                settle(app, 1)
                attach(app, "10c-stats-off")
                XCTAssertFalse(app.staticTexts["screen.stats"].exists, "stats line still shown")
                app.buttons["screen.options"].tap()
                app.buttons["Stream stats"].firstMatch.tapIfExists()
            }
            // Back to Direct Touch for the rest of the run.
            app.buttons["screen.options"].tap()
            if app.buttons["Input"].firstMatch.waitForExistence(timeout: 5) {
                app.buttons["Input"].firstMatch.tap()
                if app.buttons["Direct Touch"].firstMatch.waitForExistence(timeout: 5) { app.buttons["Direct Touch"].firstMatch.tap() }
            }
        } else {
            app.tap()
        }

        // Landscape: the shared screen turns with the phone.
        XCUIDevice.shared.orientation = .landscapeLeft
        settle(app, 2.5)
        attach(app, "11-landscape")
        XCUIDevice.shared.orientation = .portrait
        settle(app, 2)

        // Close: the session ends on both sides, the app is portrait again.
        app.buttons["screen.close"].tap()
        XCTAssertTrue(macRow.waitForExistence(timeout: 20), "back on the page\n\(app.debugDescription)")
        attach(app, "12-closed")
    }

    // MARK: Helpers

    /// First-run setup on a fresh simulator: personal space, then past the optional steps.
    @MainActor
    func passSetup(_ app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !app.tabBars.firstMatch.exists {
            if app.buttons["setup.teams.personal"].exists { app.buttons["setup.teams.personal"].tap(); continue }
            if let button = ["Not now", "Continue", "Skip", "Done", "Allow"].lazy.map({ app.buttons[$0].firstMatch }).first(where: \.isHittable) {
                button.tap()
                continue
            }
            _ = app.tabBars.firstMatch.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "shell\n\(app.debugDescription)")
    }

    @MainActor
    func wait(for element: XCUIElement, enabled: Bool, timeout: TimeInterval) -> Bool {
        let done = expectation(for: NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled)), evaluatedWith: element)
        return XCTWaiter().wait(for: [done], timeout: timeout) == .completed
    }

    /// Lets the Mac's next frames arrive before a screenshot (a bounded wait on the test clock, not app sync).
    @MainActor
    func settle(_ app: XCUIApplication, _ seconds: TimeInterval) {
        _ = app.staticTexts["never-appears"].waitForExistence(timeout: seconds)
    }

    @MainActor
    func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

extension XCUIElement {
    func tapIfExists() { if exists { tap() } }
}

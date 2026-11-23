import XCTest

/// A walk through the key row for a screen recording (cmux#51486): Lawrence asked for a video, to see that
/// it looks good "and it's not just some placeholder lookng weird nub that goes up" (Leo, 2026-11-23).
/// One terminal opened from the Workspaces list, the keyboard coming up with the key row riding it, the
/// row scrolled past the hairline to the launchers, a launcher tap that types without Return, and the
/// keyboard key hiding and showing the keyboard. Each step prints `KEYROWTOUR t=<unix s> event=<name>`
/// on the test host's clock, the clock `ui-video-start.txt` stamps the recording's first frame with.
///
///     cmux-ci run --class simulator --script scripts/ci/cmux-next-ios-sim.sh --ref SHA \
///       --arg test --arg ui=KeyRowVideoTourUITests --arg video --artifact artifacts/ios-sim/evidence.zip
final class KeyRowVideoTourUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    private func mark(_ event: String) {
        print(String(format: "KEYROWTOUR t=%.3f event=%@", Date().timeIntervalSince1970, event))
    }

    private func hold(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "keyrow-tour-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testKeyRowTour() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "workspaces"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "12"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-AppleInterfaceStyle", "Dark",
                                "-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()
        mark("launched")

        let row = app.buttons["workspace.row.ws-s2"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the workspace list\n\(app.debugDescription)")
        for _ in 0 ..< 6 where !(row.exists && row.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        hold(1.5)
        shoot(app, "list")

        // Open the terminal. The tap's touch-down is in the video as the row's highlight.
        mark("open-tap")
        row.tap()
        mark("open-tapped")
        let keyboardKey = app.buttons["terminal.key.keyboard"]
        XCTAssertTrue(keyboardKey.waitForExistence(timeout: 30), "the key row\n\(app.debugDescription)")
        mark("keyrow-exists")
        // The first key tap the app takes: its response in the video bounds the time to interactive.
        if app.keyboards.count == 0 {
            mark("keyboard-key-tap-show")
            keyboardKey.tap()
            mark("keyboard-key-tapped-show")
        } else {
            mark("keyboard-already-up")
        }
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        mark("keyboard-up")
        hold(2.0)
        shoot(app, "keyboard-up")

        // Scroll the row to its end: past the arrows and the hairline to the launchers.
        let ollama = app.buttons["terminal.key.launcher-ollama"]
        let window = app.windows.firstMatch.frame
        let rowY = (keyboardKey.frame.midY - window.minY) / window.height
        mark("scroll-start")
        for _ in 0 ..< 12 where !(ollama.exists && ollama.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: rowY))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: rowY)),
                       withVelocity: 500, thenHoldForDuration: 0.1)
            hold(0.4)
        }
        mark("scroll-end")
        hold(2.0)
        shoot(app, "launchers")

        // A launcher tap types the command and presses no Return.
        let claude = app.buttons["terminal.key.launcher-claude"]
        XCTAssertTrue(claude.exists, "the Claude launcher\n\(app.debugDescription)")
        mark("launcher-tap")
        claude.tap()
        mark("launcher-tapped")
        hold(3.0)
        shoot(app, "launcher-typed")

        // The keyboard key: hide, then show.
        mark("keyboard-key-tap-hide")
        keyboardKey.tap()
        mark("keyboard-key-tapped-hide")
        hold(2.5)
        shoot(app, "keyboard-hidden")
        mark("keyboard-key-tap-show2")
        keyboardKey.tap()
        mark("keyboard-key-tapped-show2")
        hold(2.5)
        shoot(app, "keyboard-shown")
        mark("done")
        app.terminate()
    }
}

import XCTest

/// Walks the five onboarding prototypes (`OnboardingPrototypesView`, DEBUG) and
/// attaches each step as `proto~~<variant>~~<step>~~<look>`, in dark and light.
/// Pacing waits follow the prototypes' own demo timings (a Mac "found" after
/// about 2.5 s); taps go through accessibility labels.
final class OnboardingPrototypesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor func testPrototypesDark() { walkAll(.dark) }
    @MainActor func testPrototypesLight() { walkAll(.light) }

    @MainActor
    private func walkAll(_ appearance: XCUIDevice.Appearance) {
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = appearance
        let look = appearance == .dark ? "dark" : "light"
        for variant in 1...5 {
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            // The app draws in its own appearance setting, not the simulator's: pass both.
            app.launchArguments = ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore",
                                   "-cmuxMobile.settings.appearance", look,
                                   "-cmux-mobile-onboarding-prototypes", "\(variant)"]
            app.launch()
            let shot = { (step: String) in self.attach("proto~~\(variant)~~\(step)~~\(look)") }
            switch variant {
            case 1: walkLive(app, shot)
            case 2: walkThread(app, shot)
            case 3: walkHome(app, shot)
            case 4: walkScene(app, shot)
            default: walkThree(app, shot)
            }
            app.terminate()
        }
    }

    @MainActor
    private func tap(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10) {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("\(what) not found")
            return
        }
        element.tap()
    }

    @MainActor
    private func allowIfAsked() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"].firstMatch
        if alert.waitForExistence(timeout: 3) { alert.tap() }
    }

    /// A fresh simulator's keyboard shows a one-time slide-to-type tip over the screen; close it.
    @MainActor
    private func dismissKeyboardTip(_ app: XCUIApplication) {
        // Home has no Continue button of its own, so this can only be the tip.
        let tip = app.buttons["Continue"].firstMatch
        if tip.waitForExistence(timeout: 2) { tip.tap() }
    }

    @MainActor
    private func walkLive(_ app: XCUIApplication, _ shot: (String) -> Void) {
        sleep(6)
        shot("01-agent-asks")
        tap(app.buttons["Codex wants to act on MacBook Pro: git push origin feat-onboarding"], "permission banner")
        sleep(1)
        shot("02-actions")
        tap(app.buttons["Allow once"], "Allow once")
        sleep(1)
        shot("03-answered")
        tap(app.buttons["Set up cmux"], "Set up cmux")
        sleep(1)
        shot("04-sign-in")
        tap(app.buttons["Continue with Apple"], "Apple")
        sleep(1)
        shot("05-mac-looking")
        sleep(3)
        shot("06-mac-connected")
        tap(app.buttons["Continue"], "Continue")
        sleep(1)
        shot("07-notifications")
        tap(app.buttons["Turn on notifications"], "Turn on notifications")
        allowIfAsked()
        sleep(1)
        shot("08-first-task")
        tap(app.buttons["Fix the failing tests in api-server"], "starter")
        tap(app.buttons["proto.send"], "Send")
        sleep(2)
        shot("09-chief")
    }

    @MainActor
    private func walkThread(_ app: XCUIApplication, _ shot: (String) -> Void) {
        sleep(4)
        shot("01-hello")
        tap(app.buttons["Continue with Google"], "Google")
        sleep(4)
        shot("02-mac-waiting")
        sleep(5)
        shot("03-notifications")
        tap(app.buttons["Turn on notifications"], "Turn on notifications")
        allowIfAsked()
        sleep(3)
        shot("04-first-task")
        tap(app.buttons["Fix the failing tests in api-server"], "starter")
        tap(app.buttons["proto.send"], "Send")
        sleep(5)
        shot("05-plan")
        tap(app.buttons["Max"], "Max")
        sleep(1)
        shot("06-max")
        tap(app.buttons["Maybe later"], "Maybe later")
        sleep(2)
        shot("07-done")
    }

    @MainActor
    private func walkHome(_ app: XCUIApplication, _ shot: (String) -> Void) {
        sleep(2)
        shot("01-welcome")
        tap(app.buttons["More options"], "More options")
        sleep(1)
        shot("02-more-options")
        tap(app.buttons["Continue with Apple"], "Apple")
        sleep(2)
        shot("03-home")
        tap(app.buttons["proto.setup.mac"], "Connect your Mac row")
        sleep(1)
        shot("04-connect-sheet")
        sleep(4)
        shot("05-mac-connected")
        tap(app.buttons["proto.setup.notifications"], "notifications row")
        sleep(1)
        shot("06-notifications-sheet")
        tap(app.buttons["proto.notifications.allow"], "Turn on notifications in the sheet")
        allowIfAsked()
        sleep(1)
        shot("07-two-done")
        tap(app.buttons["Fix the failing tests in api-server"].firstMatch, "starter")
        dismissKeyboardTip(app)
        sleep(1)
        shot("08-typing")
        tap(app.buttons["proto.send"], "Send")
        sleep(1)
        shot("09-task-started")
        sleep(4)
        shot("10-all-set")
    }

    @MainActor
    private func walkScene(_ app: XCUIApplication, _ shot: (String) -> Void) {
        sleep(2)
        shot("01-welcome")
        tap(app.buttons["Get started"], "Get started")
        sleep(1)
        shot("02-sign-in")
        tap(app.buttons["Continue with Apple"], "Apple")
        sleep(1)
        shot("03-looking")
        sleep(3)
        shot("04-connected")
        tap(app.buttons["Continue"], "Continue")
        sleep(1)
        shot("05-notified")
        tap(app.buttons["Turn on notifications"], "Turn on notifications")
        allowIfAsked()
        sleep(1)
        shot("06-first-task")
        tap(app.buttons["Fix the failing tests in api-server"], "starter")
        sleep(4)
        shot("07-running")
    }

    @MainActor
    private func walkThree(_ app: XCUIApplication, _ shot: (String) -> Void) {
        sleep(2)
        shot("01-welcome")
        tap(app.buttons["Other ways to sign in"], "Other ways")
        sleep(1)
        shot("02-other-sign-in")
        tap(app.buttons["Continue with GitHub"], "GitHub")
        sleep(1)
        shot("03-mac-looking")
        sleep(3)
        shot("04-mac-found")
        tap(app.buttons["Continue"], "Continue")
        sleep(1)
        shot("05-notifications")
        tap(app.buttons["Turn on notifications"], "Turn on notifications")
        allowIfAsked()
        sleep(1)
        shot("06-first-task")
        tap(app.buttons["Start"], "Start")
        sleep(4)
        shot("07-running")
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

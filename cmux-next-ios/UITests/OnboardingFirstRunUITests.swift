import XCTest

/// The first-run onboarding, end to end on mock data: Welcome, email sign-in,
/// "Here's how cmux works", the space choice, Connect your Mac, notifications
/// and "Start your first agent", which hands its task to Chief.
///
/// `testFlow*` check behavior (each fails without the onboarding's last page
/// or its hand-off). `testCapture*` attach every page in light and dark, at the
/// default text size and at accessibility sizes, with its error, waiting,
/// typed, back and skip states (`uistate~~…` attachments, `UIStateCapture.swift`).
final class OnboardingFirstRunUITests: UIStateCaptureCase {
    typealias C = UIStateCaptureCase
    private static let signedOut = ["CMUX_MOBILE_MOCK_AUTH": "1", "CMUX_MOBILE_CLEAR_AUTH": "1"]
    private static let mock = ["CMUX_MOBILE_MOCK_AUTH": "1"]
    /// A fresh first run: setup not done, nothing restored.
    private static let firstRun = ["-cmux-mobile-no-restore", "-cmuxMobile.setupComplete", "NO"]
    private static let axText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
    private static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]

    private static func at(_ step: String, _ extra: [String] = []) -> [String] {
        firstRun + ["-cmux-mobile-setup-step", step] + extra
    }

    // MARK: - Behavior

    @MainActor
    private func launch(_ args: [String], env: [String: String] = mock) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += args
        for (key, value) in env { app.launchEnvironment[key] = value }
        app.launch()
        return app
    }

    /// A first run ends on "Start your first agent"; a starter opens Chief on
    /// Home with that task sent.
    @MainActor
    func testFlowStarterOpensChiefWithTheTask() {
        let app = launch(Self.firstRun)
        defer { app.terminate() }
        var seen: [String] = []
        let starter = app.buttons["setup.first-chat.starter.tour"]
        for _ in 0..<10 where !starter.exists {
            if app.buttons["setup.intro.continue"].exists {
                seen.append("intro")
                app.buttons["setup.intro.continue"].tap()
            } else if app.scrollViews["setup.teams.choose"].exists, app.buttons["Manaflow"].exists {
                seen.append("team")
                app.buttons["Manaflow"].tap()
            } else if app.buttons["setup.pair-mac.cta"].exists {
                seen.append("pair-mac")
                app.buttons["setup.pair-mac.cta"].tap()
            } else if app.buttons["Not now"].exists {
                seen.append("not-now")
                app.buttons["Not now"].tap()
            } else {
                _ = waitForAny(app, ["setup.intro.continue", "setup.first-chat.starter.tour", "setup.pair-mac.cta", "Not now", "Manaflow"])
            }
        }
        XCTAssertEqual(seen.first, "intro", "setup must open with Here's how cmux works (pages: \(seen))")
        XCTAssertTrue(starter.waitForExistence(timeout: 15), "setup must end on Start your first agent (pages: \(seen))\n\(app.debugDescription)")
        attachShot(group: "flow", id: "first-chat-before-tap", look: .dark, miss: nil)
        starter.tap()
        let sent = C.label(app, contains: "Give me a short tour")
        XCTAssertTrue(sent.waitForExistence(timeout: 20), "Chief must open with the starter's task\n\(app.debugDescription)")
        attachShot(group: "flow", id: "chief-after-starter", look: .dark, miss: nil)
        XCTAssertFalse(app.buttons["setup.first-chat.skip"].exists, "setup must be gone after a starter")
    }

    /// Skip for now leaves setup on Home and sends nothing.
    @MainActor
    func testFlowSkipLandsOnHome() {
        let app = launch(Self.at("firstChat"))
        defer { app.terminate() }
        let skip = app.buttons["setup.first-chat.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 20), "first agent page\n\(app.debugDescription)")
        skip.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "Skip for now must land on Home\n\(app.debugDescription)")
        XCTAssertFalse(C.label(app, contains: "Give me a short tour").exists, "Skip must send nothing")
        attachShot(group: "flow", id: "home-after-skip", look: .dark, miss: nil)
    }

    /// A typed task is sent only once there is text, and opens Chief with it.
    @MainActor
    func testFlowTypedTaskSends() {
        let app = launch(Self.at("firstChat"))
        defer { app.terminate() }
        let send = app.buttons["setup.first-chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20), "send button\n\(app.debugDescription)")
        XCTAssertFalse(send.isEnabled, "send must wait for text")
        let field = app.textFields["setup.first-chat.field"].exists ? app.textFields["setup.first-chat.field"] : app.textViews["setup.first-chat.field"]
        field.tap()
        field.typeText("Rename the README title to cmux NEXT")
        XCTAssertTrue(send.isEnabled, "send must enable with text")
        send.tap()
        XCTAssertTrue(C.label(app, contains: "Rename the README title").waitForExistence(timeout: 20),
                      "Chief must open with the typed task\n\(app.debugDescription)")
    }

    /// Back from the last page returns to the page before it, and Continue on
    /// the intro moves forward.
    @MainActor
    func testFlowBackReturnsToThePreviousPage() {
        let app = launch(Self.at("firstChat"))
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["setup.first-chat.skip"].waitForExistence(timeout: 20), "first agent page\n\(app.debugDescription)")
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back on the first agent page\n\(app.debugDescription)")
        back.tap()
        XCTAssertTrue(app.buttons["Turn on notifications"].waitForExistence(timeout: 10),
                      "Back must return to the notifications page\n\(app.debugDescription)")
    }

    @MainActor
    private func waitForAny(_ app: XCUIApplication, _ ids: [String], timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ids.contains(where: { app.buttons[$0].exists }) { return true }
            Self.pause(0.3)
        }
        return false
    }

    // MARK: - Every page, every state

    @MainActor
    func testCaptureSignIn() {
        let g = "A Welcome and sign-in"
        capture([
            Scene(group: g, id: "welcome", env: Self.signedOut, signedIn: false, settle: 6),
            Scene(group: g, id: "welcome-intro-midway", args: ["-cmux-mobile-intro-freeze", "1.4"], env: Self.signedOut, signedIn: false, settle: 3),
            Scene(group: g, id: "welcome-error", args: ["-cmux-mobile-welcome-error"], env: Self.signedOut, signedIn: false, settle: 6),
            Scene(group: g, id: "welcome-large-text", args: Self.largeText, env: Self.signedOut, signedIn: false, settle: 6),
            Scene(group: g, id: "welcome-ax-text", args: Self.axText, env: Self.signedOut, signedIn: false, settle: 6),
            Scene(group: g, id: "email", env: Self.signedOut, signedIn: false, settle: 5) { app in
                C.tap(C.label(app, contains: "Continue with email"), "Continue with email")
            },
            Scene(group: g, id: "email-code", args: ["-cmux-mobile-email", "someone@example.com", "-cmux-mobile-no-restore"],
                  env: Self.signedOut, signedIn: false, settle: 4) { app in
                C.wait(app.textFields["Code"].firstMatch, "code field")
            },
            Scene(group: g, id: "email-code-wrong", args: ["-cmux-mobile-email", "someone@example.com", "-cmux-mobile-no-restore"],
                  env: Self.signedOut, signedIn: false, settle: 4) { app in
                C.steps([
                    { C.showKeyboard(app, field: app.textFields["Code"].firstMatch, "code field") },
                    { app.typeText("111111"); return nil },
                ])
            },
        ])
    }

    @MainActor
    func testCaptureSetup() {
        let g = "B Setup"
        capture([
            Scene(group: g, id: "intro", args: Self.firstRun, env: Self.mock, signedIn: false, settle: 3) { app in
                C.wait(app.buttons["setup.intro.continue"], "intro")
            },
            Scene(group: g, id: "intro-large-text", args: Self.firstRun + Self.largeText, env: Self.mock, signedIn: false, settle: 3) { app in
                C.wait(app.buttons["setup.intro.continue"], "intro")
            },
            Scene(group: g, id: "intro-ax-text", args: Self.firstRun + Self.axText, env: Self.mock, signedIn: false, settle: 3) { app in
                C.wait(app.buttons["setup.intro.continue"], "intro")
            },
            Scene(group: g, id: "team-after-continue", args: Self.firstRun, env: Self.mock, signedIn: false, settle: 3) { app in
                C.steps([
                    { C.tap(app.buttons["setup.intro.continue"], "intro Continue") },
                    { C.wait(app.scrollViews["setup.teams.choose"], "team chooser") },
                ])
            },
            Scene(group: g, id: "pair-mac-waiting", args: Self.at("pairMac", ["-cmux-mobile-setup-no-mac"]), env: Self.mock, signedIn: false, settle: 4),
            Scene(group: g, id: "pair-mac-found", args: Self.at("pairMac"), env: Self.mock, signedIn: false, settle: 4),
            Scene(group: g, id: "notifications", args: Self.at("notifications"), env: Self.mock, signedIn: false, settle: 3),
            Scene(group: g, id: "signout-confirm", args: Self.firstRun, env: Self.mock, signedIn: false, settle: 3) { app in
                C.tap(C.any(app, "setup.sign-out"), "setup sign-out")
            },
        ])
    }

    @MainActor
    func testCaptureFirstChat() {
        let g = "C Start your first agent"
        capture([
            Scene(group: g, id: "first-chat-mac-online", args: Self.at("firstChat"), env: Self.mock, signedIn: false, settle: 3),
            Scene(group: g, id: "first-chat-waiting-for-mac", args: Self.at("firstChat", ["-cmux-mobile-setup-no-mac"]), env: Self.mock,
                  signedIn: false, settle: 3),
            Scene(group: g, id: "first-chat-typing", args: Self.at("firstChat"), env: Self.mock, signedIn: false, settle: 3) { app in
                C.steps([
                    { C.showKeyboard(app, field: C.any(app, "setup.first-chat.field"), "first agent field") },
                    { app.typeText("Rename the README title to cmux NEXT"); return nil },
                ])
            },
            Scene(group: g, id: "first-chat-large-text", args: Self.at("firstChat", Self.largeText), env: Self.mock, signedIn: false, settle: 3),
            Scene(group: g, id: "first-chat-ax-text", args: Self.at("firstChat", Self.axText), env: Self.mock, signedIn: false, settle: 3),
            Scene(group: g, id: "after-starter-chief", args: Self.at("firstChat"), env: Self.mock, signedIn: false, settle: 3) { app in
                C.steps([
                    { C.tap(app.buttons["setup.first-chat.starter.tour"], "Explain my project starter") },
                    { C.wait(C.label(app, contains: "Give me a short tour"), "the task in Chief") },
                ])
            },
            Scene(group: g, id: "after-skip-home", args: Self.at("firstChat"), env: Self.mock, signedIn: false, settle: 3) { app in
                C.steps([
                    { C.tap(app.buttons["setup.first-chat.skip"], "Skip for now") },
                    { C.wait(app.tabBars.firstMatch, "Home tab bar") },
                ])
            },
            Scene(group: g, id: "after-back-notifications", args: Self.at("firstChat"), env: Self.mock, signedIn: false, settle: 3) { app in
                C.steps([
                    { C.tap(app.navigationBars.buttons.firstMatch, "Back") },
                    { C.wait(app.buttons["Turn on notifications"], "notifications page") },
                ])
            },
        ])
    }
}

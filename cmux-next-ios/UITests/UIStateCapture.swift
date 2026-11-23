import XCTest

/// Shared harness for the all-UI-states capture suites (`AllUIStates*CaptureUITests`).
///
/// Each scene launches the DEBUG app on mock data with its own launch
/// arguments and environment, walks to one UI state with real taps, and
/// attaches a full-screen screenshot (system alerts included) named
/// `uistate~~<group>~~<id>~~<look>`, in light and in dark. A scene that cannot
/// reach its state never fails the run: it prints `UISTATE-MISS <id> <reason>`
/// to the console and attaches what the screen shows instead, named
/// `uimiss~~…~~<reason>`, so the artifact lists it as missing with its reason.
/// `cmuxterm-hq/artifacts/ios-all-ui-states/` is built from these attachments.
class UIStateCaptureCase: XCTestCase {
    enum Look: String, CaseIterable {
        case light, dark
        var device: XCUIDevice.Appearance { self == .dark ? .dark : .light }
    }

    /// One state to capture.
    struct Scene {
        var group: String
        var id: String
        var args: [String] = []
        var env: [String: String] = [:]
        /// Signed in on mock data with setup done (the usual start).
        var signedIn = true
        /// Looks to capture; both by default.
        var looks: [Look] = Look.allCases
        /// Seconds to let a demo driver settle before the first check.
        var settle: Double = 2.5
        /// Walks to the state. Returns nil when it reached it, or why not.
        var reach: @MainActor (XCUIApplication) -> String? = { _ in nil }
        /// A timed demo (its driver steps through states on its own clock):
        /// one shot per entry, `(state id, seconds after launch)`, in order.
        /// When set, `id` names the demo and `reach` runs before the first.
        var frames: [(String, Double)] = []
    }

    override func setUp() {
        continueAfterFailure = true
    }

    /// Captures every scene in both looks; misses are reported, never fatal.
    @MainActor
    func capture(_ scenes: [Scene]) {
        for scene in scenes {
            for look in scene.looks {
                XCUIDevice.shared.appearance = look.device
                XCUIDevice.shared.orientation = .portrait
                let app = XCUIApplication()
                if scene.signedIn {
                    app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
                    if !scene.args.contains("-cmux-mobile-setup") && !scene.args.contains("-cmuxMobile.setupComplete") {
                        app.launchArguments += ["-cmuxMobile.setupComplete", "YES"]
                    }
                }
                if !scene.args.contains("-cmux-mobile-demo") && !scene.args.contains("-cmux-mobile-tab") {
                    app.launchArguments += ["-cmux-mobile-no-restore"]
                }
                app.launchArguments += ["-cmuxMobile.settings.appearance", look.rawValue]
                app.launchArguments += scene.args
                for (key, value) in scene.env { app.launchEnvironment[key] = value }
                app.launch()
                // Scene-level settle: demo drivers pace themselves with no signal to wait on.
                _ = app.wait(for: .runningForeground, timeout: 20)
                Self.pause(scene.settle)
                if scene.signedIn { pickTeamIfAsked(app) }
                if !scene.frames.isEmpty {
                    let launched = Date()
                    let miss = scene.reach(app)
                    for (state, at) in scene.frames {
                        let left = at - Date().timeIntervalSince(launched)
                        if left > 0 { Self.pause(left) }
                        attachShot(group: scene.group, id: state, look: look, miss: miss)
                    }
                    app.terminate()
                    continue
                }
                let miss = scene.reach(app)
                Self.pause(0.8)
                attachShot(group: scene.group, id: scene.id, look: look, miss: miss)
                app.terminate()
            }
        }
    }

    @MainActor
    func attachShot(group: String, id: String, look: Look, miss: String?) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        if let miss {
            print("UISTATE-MISS \(group)|\(id)|\(look.rawValue) \(miss)")
            shot.name = "uimiss~~\(group)~~\(id)~~\(look.rawValue)~~\(miss)"
        } else {
            print("UISTATE-OK \(group)|\(id)|\(look.rawValue)")
            shot.name = "uistate~~\(group)~~\(id)~~\(look.rawValue)"
        }
        add(shot)
    }

    /// Mock sign-in can open on "Choose a space" when setup is not marked done.
    @MainActor
    func pickTeamIfAsked(_ app: XCUIApplication) {
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.exists, app.buttons["Manaflow"].exists { app.buttons["Manaflow"].tap() }
    }

    /// A bounded settle for demo drivers and animations, which give the test no signal to wait on.
    static func pause(_ seconds: Double) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    // MARK: - Small reach helpers (each returns nil on success, or why not)

    @MainActor
    static func tap(_ element: XCUIElement, _ what: String, timeout: Double = 15) -> String? {
        guard element.waitForExistence(timeout: timeout) else { return "no \(what)" }
        guard onScreen(element) else { return "\(what) is not on screen" }
        // A coordinate tap never throws on an element that is not hittable (off screen, under a bar).
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return nil
    }

    /// An element with a finite, non-empty frame (a coordinate on any other raises).
    @MainActor
    static func onScreen(_ element: XCUIElement) -> Bool {
        let f = element.frame
        return f.origin.x.isFinite && f.origin.y.isFinite && f.width.isFinite && f.height.isFinite && !f.isEmpty
    }

    @MainActor
    static func wait(_ element: XCUIElement, _ what: String, timeout: Double = 20) -> String? {
        element.waitForExistence(timeout: timeout) ? nil : "no \(what)"
    }

    @MainActor
    static func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    static func label(_ app: XCUIApplication, contains text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    @MainActor
    static func button(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons[name].firstMatch
    }

    @MainActor
    static func tabBar(_ app: XCUIApplication, _ name: String) -> String? {
        tap(app.tabBars.buttons[name].firstMatch, "tab bar \(name)")
    }

    /// Chains steps, stopping at the first one that misses.
    @MainActor
    static func steps(_ list: [@MainActor () -> String?]) -> String? {
        for step in list { if let miss = step() { return miss } }
        return nil
    }

    @MainActor
    static func showKeyboard(_ app: XCUIApplication, field: XCUIElement, _ what: String) -> String? {
        guard field.waitForExistence(timeout: 20) else { return "no \(what)" }
        field.tap()
        return app.keyboards.firstMatch.waitForExistence(timeout: 8) ? nil : "keyboard did not show for \(what)"
    }

    @MainActor
    static func swipeLeft(_ element: XCUIElement, _ what: String) -> String? {
        guard element.waitForExistence(timeout: 15) else { return "no \(what)" }
        guard onScreen(element) else { return "\(what) is not on screen" }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        return nil
    }

    @MainActor
    static func swipeRight(_ element: XCUIElement, _ what: String) -> String? {
        guard element.waitForExistence(timeout: 15) else { return "no \(what)" }
        guard onScreen(element) else { return "\(what) is not on screen" }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        return nil
    }

    @MainActor
    static func longPress(_ element: XCUIElement, _ what: String) -> String? {
        guard element.waitForExistence(timeout: 15) else { return "no \(what)" }
        guard onScreen(element) else { return "\(what) is not on screen" }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        return nil
    }

    @MainActor
    static func scrollDown(_ app: XCUIApplication, times: Int = 1) -> String? {
        for _ in 0..<times {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        }
        return nil
    }
}

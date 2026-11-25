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
        /// What the scene waits for before its reach and its shot (`Ready`).
        var ready: Ready = .auto
        /// Walks to the state. Returns nil when it reached it, or why not.
        var reach: @MainActor (XCUIApplication) -> String? = { _ in nil }
        /// A timed demo (its driver steps through states on its own clock):
        /// one shot per entry, `(state id, seconds after launch)`, in order.
        /// When set, `id` names the demo and `reach` runs before the first.
        var frames: [(String, Double)] = []
    }

    /// What a scene waits for after launch. Nothing waits a fixed time unless
    /// the scene says `.clock`: a state reached by taps is waited on by its
    /// `reach` steps (each waits for its element), and XCUITest waits for the
    /// app to idle after every tap, so the shot follows the last step at once.
    enum Ready {
        /// The launch path's own signal: a `-cmux-mobile-demo` scene waits for
        /// its driver's `demo_done` launch mark (its last step on screen and
        /// still), a list rig still (`CMUX_MOBILE_LIST_SCREEN`, no passes) for
        /// `list_hold`, any other signed-in scene for `shell_still` (the shell's
        /// first state, still); a gallery or demo root for its own element
        /// (`rootElement`). Anything else (signed out, a standalone demo)
        /// waits for nothing here: its `reach`, or a `.element`, waits.
        case auto
        /// A launch mark (`debug.launch-marks`) was taken.
        case mark(String)
        /// An element with this identifier exists.
        case element(String)
        /// keep: the shot is a moment on a clock the app keeps (a timed demo
        /// step, a delay the state is about), and nothing on screen marks it:
        /// this many seconds after launch.
        case clock(Double)
    }

    /// How long a scene's signal may take before the shot goes ahead anyway.
    static let readyTimeout: Double = 30

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
                // The launch marks (`demo_done`, `shell_frame`) as a label the scene can wait on.
                app.launchEnvironment["CMUX_MOBILE_LAUNCH_MARKS"] = "1"
                app.launch()
                _ = app.wait(for: .runningForeground, timeout: 20)
                let launched = Date()
                // A timed demo's frames are its clock; its end (`demo_done`) comes after the last.
                if scene.frames.isEmpty { waitReady(app, scene, launched: launched) }
                if scene.signedIn { pickTeamIfAsked(app) }
                if !scene.frames.isEmpty {
                    let miss = scene.reach(app)
                    for (state, at) in scene.frames {
                        let left = at - Date().timeIntervalSince(launched)
                        // keep: each frame is a step of the demo driver's own clock, which shows no marker per step.
                        if left > 0 { Self.pause(left) }
                        attachShot(group: scene.group, id: state, look: look, miss: miss)
                    }
                    app.terminate()
                    continue
                }
                let miss = scene.reach(app)
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

    /// Waits for the scene's `Ready` signal, bounded by `readyTimeout`.
    @MainActor
    func waitReady(_ app: XCUIApplication, _ scene: Scene, launched: Date) {
        switch scene.ready {
        case .clock(let seconds):
            let left = seconds - Date().timeIntervalSince(launched)
            // keep: `.clock` scenes are a moment on the app's own clock (see `Ready.clock`).
            if left > 0 { Self.pause(left) }
        case .element(let id):
            waitElement(app, scene, id)
        case .mark(let name):
            waitMark(app, scene, name)
        case .auto:
            if scene.args.contains("-cmux-mobile-demo") {
                waitMark(app, scene, "demo_done")
            } else if scene.env["CMUX_MOBILE_LIST_SCREEN"] != nil && scene.env["CMUX_MOBILE_LIST_PASSES"] == "0" {
                waitMark(app, scene, "list_hold")
            } else if let id = Self.rootElement(scene.args) {
                if !id.isEmpty { waitElement(app, scene, id) }
            } else if scene.signedIn {
                waitMark(app, scene, "shell_still")
            }
        }
    }

    @MainActor
    private func waitElement(_ app: XCUIApplication, _ scene: Scene, _ id: String) {
        if !Self.any(app, id).waitForExistence(timeout: Self.readyTimeout) {
            print("UISTATE-SLOW \(scene.group)|\(scene.id) no \(id) after \(Int(Self.readyTimeout))s")
        }
    }

    @MainActor
    private func waitMark(_ app: XCUIApplication, _ scene: Scene, _ name: String) {
        if !Self.waitForMark(name, in: app, timeout: Self.readyTimeout) {
            print("UISTATE-SLOW \(scene.group)|\(scene.id) no \(name) mark after \(Int(Self.readyTimeout))s")
        }
    }

    /// For a launch that puts a root of its own in place of the shell (CmuxMobileApp's root switch):
    /// the element that root shows once up ("" for none), or nil for the shell.
    static func rootElement(_ args: [String]) -> String? {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let gallery = value("-cmux-mobile-recovery-gallery") { return "recoveryGallery.\(gallery)" }
        if args.contains("-cmux-mobile-browser-events") { return "browser.page" }
        if args.contains("-CmuxMobileScreenSharingDemo") {
            // Connected: the trackpad's notch shows; a locked or asleep Mac's notice once the picture is judged.
            return args.contains("-CmuxMobileScreenSharingDemoSource") ? "screen.sourceNotice" : "screen.trackpad.handle"
        }
        if args.contains("-CmuxMobileTerminalDemo") || args.contains("-CmuxMobileDemo") { return "" }
        return nil
    }

    /// Whether the launch mark `name` was taken (`debug.launch-marks`, CMUX_MOBILE_LAUNCH_MARKS=1), bounded.
    @MainActor
    static func waitForMark(_ name: String, in app: XCUIApplication, timeout: Double) -> Bool {
        let probe = app.staticTexts["debug.launch-marks"]
        let taken = NSPredicate { object, _ in
            guard let label = (object as? XCUIElement)?.label, let data = label.data(using: .utf8),
                  let marks = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return false }
            return marks[name] != nil
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: taken, object: probe)], timeout: timeout) == .completed
    }

    /// Polls `ok` until it holds, bounded: for a state an element's property shows
    /// (a frame, an orientation) that no element's existence marks.
    @MainActor
    static func until(_ timeout: Double, _ ok: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ok() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return ok()
    }

    /// A fixed wait on the test clock. Only for a moment on the app's own clock
    /// that nothing on screen marks; each call says why with a `// keep:` comment.
    static func pause(_ seconds: Double) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: seconds)
    }

    /// A sent agent turn ran to its end: its Stop button came and went (bounded).
    @MainActor
    static func turnEnded(_ app: XCUIApplication, timeout: Double = 60) -> String? {
        let stop = app.buttons["Stop"].firstMatch
        _ = stop.waitForExistence(timeout: 10)
        return stop.waitForNonExistence(timeout: timeout) ? nil : "turn still running after \(Int(timeout))s"
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

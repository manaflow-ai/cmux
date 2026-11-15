import XCTest

/// The first-user journey on iPhone: what a new person sees and taps, from a
/// fresh install through sign-in, setup, pairing, Home and its tabs, a chat,
/// Settings and every Settings page, the Face ID lock, and the app's error
/// states, at the default, the smallest and the largest text size.
///
/// Each screen is judged by the same rules the web and Mac journeys use:
///
/// - `error-without-next-step`: error words on screen and no control that
///   offers a way on (Retry, Open Settings, Sign in, Connect, ...).
/// - `raw-error-code`: an error domain, a numeric code, a Swift error case or
///   "The operation couldn't be completed" shown to the person.
/// - `dead-button`: a tap that changes nothing (navigation, a sheet, an alert,
///   a state change or a hand-off to another app all count).
/// - `permanent-spinner`: a progress indicator still spinning after 20 s.
/// - `permission-prompt-without-explanation`: a system permission alert whose
///   permission the screen before it never mentioned.
/// - `layout-break`: a control or text cut off at a side of the window, or two
///   tappable controls on top of each other.
/// - `crash`: the app stopped running.
///
/// Every step prints one `FUJ {json}` line; `cmux-next-ios/scripts/first_user_journey_report.py`
/// turns those lines and the exported screenshots into results.json and
/// summary.md. A red is recorded, never asserted, so one run walks every
/// screen; the test fails only when the journey itself cannot run.
///
/// It runs on a Debug build with the app's mock account
/// (`CMUX_MOBILE_MOCK_AUTH`, DEBUG only): no person's login is used.
/// `.github/workflows/first-user-journey-ios.yml` runs it nightly.
final class FirstUserJourneyUITests: XCTestCase {
    /// The whole journey's budget: every test stops walking once it is spent,
    /// so the run always ends with results (run 43210992635 walked past an hour).
    nonisolated(unsafe) static var journeyDeadline: Date?
    static let journeyBudget: TimeInterval = 30 * 60
    /// One test's budget; the walk stops tapping when it is spent and says so.
    static let testBudget: TimeInterval = 4 * 60

    private var testDeadline = Date.distantFuture
    private var stepCount = 0
    private var shotCount = 0

    override func setUpWithError() throws {
        continueAfterFailure = true
        executionTimeAllowance = Self.testBudget + 120
        let start = Date()
        if Self.journeyDeadline == nil { Self.journeyDeadline = start.addingTimeInterval(Self.journeyBudget) }
        testDeadline = min(start.addingTimeInterval(Self.testBudget), Self.journeyDeadline ?? .distantFuture)
        // A system alert (a permission the walk did not expect) never blocks the
        // simulator: answer it without granting and go on.
        addUIInterruptionMonitor(withDescription: "system alert") { alert in
            for answer in ["Don’t Allow", "Don't Allow", "Not Now", "Cancel", "OK"] where alert.buttons[answer].exists {
                alert.buttons[answer].tap()
                return true
            }
            return false
        }
    }

    private var outOfTime: Bool { Date() >= testDeadline }

    // MARK: - Journey

    /// Fresh install: signed out, permissions never asked. Sign-in's controls
    /// each do something, and none of them asks for a permission unexplained.
    @MainActor
    func testA_FreshInstallSignIn() throws {
        let cell = "ios/sign-in"
        begin(cell)
        let app = XCUIApplication()
        for resource in [XCUIProtectedResource.camera, .microphone, .photos] {
            app.resetAuthorizationStatus(for: resource)
        }
        let launched = launch(app: app, signedIn: false)
        let email = launched.buttons["Continue with email"]
        guard email.waitForExistence(timeout: 30) else {
            red(cell, "crash", where: "sign-in", step: "launch signed out",
                detail: "sign-in never showed: \(onScreen(launched))", app: launched)
            finish(cell)
            return
        }
        judge(cell, where: "sign-in", step: "launch signed out", app: launched)
        launched.terminate()
        walk(cell, where: "sign-in", reach: {
            let app = self.launch(signedIn: false)
            _ = app.buttons["Continue with email"].waitForExistence(timeout: 30)
            return app
        })
        finish(cell)
    }

    /// Setup after the first sign-in: every page offers a way on, and the
    /// notification page explains before the system asks.
    @MainActor
    func testB_Onboarding() throws {
        let cell = "ios/onboarding"
        begin(cell)
        let app = launch(setupComplete: false)
        var seen: [String] = []
        for _ in 0..<8 {
            if app.tabBars.firstMatch.exists { break }
            if app.scrollViews["setup.teams.choose"].exists, app.buttons["Manaflow"].exists {
                seen.append("team")
                judge(cell, where: "onboarding/team", step: "team page", app: app)
                app.buttons["Manaflow"].tap()
            } else if app.buttons["setup.pair-mac.cta"].exists {
                seen.append("pair-mac")
                judge(cell, where: "onboarding/pair-mac", step: "Connect your Mac page", app: app)
                app.buttons["setup.pair-mac.cta"].tap()
            } else if app.buttons["Turn on notifications"].exists {
                seen.append("notifications")
                judge(cell, where: "onboarding/notifications", step: "notifications page", app: app)
                let before = screenText(app)
                app.buttons["Turn on notifications"].tap()
                permissionCheck(cell, where: "onboarding/notifications", step: "tap 'Turn on notifications'",
                                before: before, app: app)
            } else if app.buttons["Not now"].exists {
                seen.append("not-now")
                judge(cell, where: "onboarding/other", step: "setup page with Not now", app: app)
                app.buttons["Not now"].tap()
            } else {
                _ = waitForAny([app.tabBars.firstMatch, app.scrollViews["setup.teams.choose"],
                                app.buttons["setup.pair-mac.cta"], app.buttons["Not now"]], timeout: 10)
            }
            stepCount += 1
        }
        if !app.tabBars.firstMatch.waitForExistence(timeout: 10) {
            red(cell, "error-without-next-step", where: "onboarding", step: "finish setup",
                detail: "setup did not end on Home (pages seen: \(seen.joined(separator: ",")))", app: app)
        }
        note(cell, "pages seen: \(seen.joined(separator: ","))")
        app.terminate()
        walk(cell, where: "onboarding", reach: {
            let app = self.launch(setupComplete: false)
            _ = self.waitForAny([app.scrollViews["setup.teams.choose"], app.buttons["setup.pair-mac.cta"]], timeout: 20)
            return app
        }, skip: ["setup.sign-out", "Sign out", "Sign Out"])
        finish(cell)
    }

    /// Pairing: the Connect your Mac flows (no account on the Mac, another
    /// account, a Mac elsewhere) and Settings > Devices with its scan.
    @MainActor
    func testC_Pairing() throws {
        let cell = "ios/pairing"
        begin(cell)
        for demo in ["connect-mac", "connect-mac-no-account", "connect-mac-elsewhere", "relay-only"] where !outOfTime {
            let app = launch(arguments: ["-cmux-mobile-demo", demo])
            settle(app)
            judge(cell, where: "pairing/\(demo)", step: "open \(demo)", app: app)
            app.terminate()
        }
        walk(cell, where: "settings/devices", reach: {
            let app = self.launch(arguments: ["-cmux-mobile-tab", "settings", "-cmux-mobile-settings-page", "devices"])
            self.settle(app)
            return app
        }, skip: ["settings.removeThisPhone"])
        // Scan with the camera never asked: the system prompt must follow a
        // screen that said why the camera is wanted.
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .camera)
        let launched = launch(app: app, arguments: ["-cmux-mobile-tab", "settings", "-cmux-mobile-settings-page", "devices"])
        let scan = launched.buttons["settings.scanMacCode"]
        if scan.waitForExistence(timeout: 20) {
            let before = screenText(launched)
            scan.tap()
            permissionCheck(cell, where: "settings/devices/scan", step: "tap 'Scan QR on your Mac'", before: before, app: launched)
            judge(cell, where: "settings/devices/scan", step: "after the camera answer", app: launched)
        } else {
            note(cell, "Settings > Devices showed no Scan button with the mock account")
        }
        launched.terminate()
        finish(cell)
    }

    /// Home and the tab bar's other tabs, each walked control by control.
    @MainActor
    func testD_HomeAndTabs() throws {
        for tab in ["home", "workspaces", "feed"] {
            // Three cells share this test: each gets a third of its budget.
            testDeadline = min(Date().addingTimeInterval(Self.testBudget / 3 + 20), Self.journeyDeadline ?? .distantFuture)
            let cell = "ios/\(tab)"
            begin(cell)
            let app = launch(arguments: ["-cmux-mobile-tab", tab])
            guard app.tabBars.firstMatch.waitForExistence(timeout: 30) else {
                red(cell, "crash", where: tab, step: "open \(tab)", detail: "the shell never showed: \(onScreen(app))", app: app)
                app.terminate()
                finish(cell)
                continue
            }
            settle(app)
            judge(cell, where: tab, step: "open \(tab)", app: app)
            app.terminate()
            walk(cell, where: tab, reach: {
                let app = self.launch(arguments: ["-cmux-mobile-tab", tab])
                _ = app.tabBars.firstMatch.waitForExistence(timeout: 30)
                self.settle(app)
                return app
            }, skip: ["home.row.delete"], skipPrefixes: ["home.row.swipe."])
            finish(cell)
        }
    }

    /// A chat: Chief opens, a message sends and gets a reply. Sending is where
    /// a permission prompt the person did not ask for would show.
    @MainActor
    func testE_Chat() throws {
        let cell = "ios/chat"
        begin(cell)
        let app = XCUIApplication()
        let launched = launch(app: app, arguments: ["-cmux-mobile-demo", "chief-open"])
        let field = launched.textViews["conversation.composer.text"]
        guard field.waitForExistence(timeout: 30) else {
            red(cell, "error-without-next-step", where: "chat", step: "open Chief",
                detail: "Chief never showed a message box: \(onScreen(launched))", app: launched)
            launched.terminate()
            finish(cell)
            return
        }
        judge(cell, where: "chat", step: "open Chief", app: launched)
        field.tap()
        field.typeText("Hello from the first-user journey")
        let send = launched.buttons["conversation.composer.send"]
        let before = screenText(launched)
        if send.waitForExistence(timeout: 5), send.isEnabled {
            send.tap()
            stepCount += 1
            permissionCheck(cell, where: "chat", step: "send the first message to Chief", before: before, app: launched)
            judge(cell, where: "chat", step: "after send", app: launched)
        } else {
            red(cell, "dead-button", where: "chat", step: "type a message",
                detail: "Send is missing or disabled with a draft", app: launched)
        }
        launched.terminate()
        walk(cell, where: "chat", reach: {
            let app = self.launch(arguments: ["-cmux-mobile-demo", "chief-open"])
            _ = app.textViews["conversation.composer.text"].waitForExistence(timeout: 30)
            return app
        }, skip: ["conversation.composer.send"])
        finish(cell)
    }

    /// Settings: the list walked top and bottom, and every page it opens.
    @MainActor
    func testF_Settings() throws {
        let cell = "ios/settings"
        begin(cell)
        let destructive: Set<String> = ["settings.logout", "settings.deleteAccount", "settings.removeThisPhone",
                                        "settings.developer.mock", "Quit to apply"]
        walk(cell, where: "settings", reach: {
            let app = self.launch(arguments: ["-cmux-mobile-tab", "settings"])
            _ = app.tabBars.buttons["Settings"].waitForExistence(timeout: 30)
            return app
        }, skip: destructive)
        walk(cell, where: "settings-bottom", reach: {
            let app = self.launch(arguments: ["-cmux-mobile-tab", "settings"])
            _ = app.tabBars.buttons["Settings"].waitForExistence(timeout: 30)
            for _ in 0..<6 { app.swipeUp(velocity: .fast) }
            return app
        }, skip: destructive)
        let pages = ["account", "team", "transport", "devices", "terminal", "terminalSizing", "composer", "notifications",
                     "acknowledgements", "chiefCalls", "screenSharing", "accentColor", "cloudMachines", "automations",
                     "longPressMenus"]
        for page in pages where !outOfTime {
            let app = launch(arguments: ["-cmux-mobile-tab", "settings", "-cmux-mobile-settings-page", page])
            settle(app)
            judge(cell, where: "settings/\(page)", step: "open Settings > \(page)", app: app)
            app.terminate()
        }
        finish(cell)
    }

    /// Settings > Require Face ID: turning it on must either lock the app
    /// with Face ID (the system's Face ID prompt follows the setting's own
    /// explanation) or say why it cannot. A switch that turns on and changes
    /// nothing is a dead button.
    @MainActor
    func testG_FaceIDLock() throws {
        let cell = "ios/face-id"
        begin(cell)
        // No launch argument for the setting: an argument-domain value would pin
        // the switch, so the walk starts from the fresh install's default (off).
        let app = launch(arguments: ["-cmux-mobile-tab", "settings"])
        guard app.tabBars.buttons["Settings"].waitForExistence(timeout: 30) else {
            red(cell, "crash", where: "settings", step: "open Settings", detail: onScreen(app), app: app)
            finish(cell)
            return
        }
        let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Require Face ID")).firstMatch
        scrollTo(toggle, in: app)
        guard toggle.exists else {
            red(cell, "error-without-next-step", where: "settings", step: "find Require Face ID",
                detail: "Settings has no Require Face ID switch", app: app)
            app.terminate()
            finish(cell)
            return
        }
        let before = screenText(app)
        if (toggle.value as? String) != "1" { toggle.tap() }
        stepCount += 1
        // Some builds ask for Face ID right away; judge that prompt now.
        let askedAtToggle = permissionCheck(cell, where: "settings/require-face-id", step: "turn on Require Face ID",
                                            before: before, app: app)
        // The lock holds from the next background: leave and come back.
        XCUIDevice.shared.press(.home)
        _ = app.wait(for: .runningBackground, timeout: 5)
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 10)
        let askedOnReturn = permissionCheck(cell, where: "settings/require-face-id", step: "return to cmux with Require Face ID on",
                                            before: before, app: app)
        let lock = element("cmuxMobile.appLock", in: app)
        let lockShown = lock.waitForExistence(timeout: 5)
        shot(cell, "face-id-after-return", app)
        if !lockShown && !askedAtToggle && !askedOnReturn {
            let explained = matches(screenText(app), #"(?i)passcode|set up face id|face id is (off|not)"#)
                && app.alerts.firstMatch.exists
            if !explained {
                red(cell, "dead-button", where: "settings/require-face-id", step: "turn on Require Face ID, leave, return",
                    detail: "Require Face ID turned on, but cmux did not lock and said nothing (no Face ID or passcode on this device?)",
                    app: app)
            }
        }
        if lockShown {
            judge(cell, where: "app-lock", step: "the lock screen", app: app)
        }
        app.terminate()
        // Leave the setting off for the cells after this one. (The simulator
        // has no Face ID enrolled and no passcode, so the lock cannot hold.)
        let reset = launch(arguments: ["-cmux-mobile-tab", "settings"])
        if reset.tabBars.buttons["Settings"].waitForExistence(timeout: 30) {
            let again = reset.switches.matching(NSPredicate(format: "label CONTAINS %@", "Require Face ID")).firstMatch
            scrollTo(again, in: reset)
            if again.exists, (again.value as? String) == "1" { again.tap() }
        }
        reset.terminate()
        finish(cell)
    }

    /// SSH: adding a remote host (and its Face ID-locked key). The NEXT iPhone
    /// app reaches machines through the Mac and Cloud, so this records what it
    /// finds instead of assuming the screen exists.
    @MainActor
    func testH_SSHHostAdd() throws {
        let cell = "ios/ssh-host"
        begin(cell)
        var found = false
        for tab in ["settings", "workspaces", "home"] {
            let app = launch(arguments: ["-cmux-mobile-tab", tab])
            _ = app.tabBars.firstMatch.waitForExistence(timeout: 30)
            let ssh = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] 'SSH' OR label CONTAINS[c] 'Add host' OR label CONTAINS[c] 'Remote host'"))
                .firstMatch
            if ssh.waitForExistence(timeout: 3) {
                found = true
                let before = screenText(app)
                ssh.tap()
                permissionCheck(cell, where: "\(tab)/ssh", step: "open \(ssh.label)", before: before, app: app)
                judge(cell, where: "\(tab)/ssh", step: "open \(ssh.label)", app: app)
            }
            app.terminate()
        }
        if !found {
            skipCell(cell, "no SSH or remote-host screen in the NEXT iPhone app's Settings, Workspaces or Home")
        }
        finish(cell)
    }

    /// The error states a new person meets: offline first launch, a failed
    /// first load, a failed refresh, Workspaces, Feed, a terminal and Home
    /// with the Mac gone, a message sent offline, and the recovery screens.
    @MainActor
    func testI_ErrorStates() throws {
        let cell = "ios/errors"
        begin(cell)
        let demos = ["retry-first-launch-offline", "retry-first-launch-failed", "retry-refresh-failed", "retry-workspaces",
                     "retry-feed", "retry-terminal", "retry-home-offline", "offline-send"]
        for demo in demos where !outOfTime {
            let app = launch(arguments: ["-cmux-mobile-demo", demo])
            settle(app, timeout: 8)
            judge(cell, where: "errors/\(demo)", step: "open \(demo)", app: app, spinner: false)
            app.terminate()
        }
        for scene in ["states", "card", "cloud", "home", "chiefoff", "signedout", "terminal"] where !outOfTime {
            let app = launch(arguments: ["-cmux-mobile-recovery-gallery", scene])
            settle(app, timeout: 5)
            judge(cell, where: "errors/recovery-\(scene)", step: "recovery gallery \(scene)", app: app, spinner: false)
            app.terminate()
        }
        finish(cell)
    }

    /// The smallest and the largest text size on the screens a new person
    /// sees first.
    @MainActor
    func testJ_DynamicTypeExtremes() throws {
        let cell = "ios/layout"
        begin(cell)
        let sizes = [("xs", "UICTContentSizeCategoryXS"), ("ax5", "UICTContentSizeCategoryAccessibilityXXXL")]
        for (name, category) in sizes {
            let type = ["-UIPreferredContentSizeCategoryName", category]
            let screens: [(String, Bool, Bool, [String])] = [
                ("sign-in", false, true, []),
                ("onboarding", true, false, []),
                ("home", true, true, ["-cmux-mobile-tab", "home"]),
                ("workspaces", true, true, ["-cmux-mobile-tab", "workspaces"]),
                ("settings", true, true, ["-cmux-mobile-tab", "settings"]),
                ("chat", true, true, ["-cmux-mobile-demo", "chief-open"]),
                ("pairing", true, true, ["-cmux-mobile-demo", "connect-mac"]),
            ]
            for (screen, signedIn, setupComplete, arguments) in screens where !outOfTime {
                let app = launch(signedIn: signedIn, setupComplete: setupComplete, arguments: type + arguments)
                settle(app)
                stepCount += 1
                layoutCheck(cell, where: "\(screen)@\(name)", step: "open \(screen) at text size \(name)", app: app)
                app.terminate()
            }
        }
        finish(cell)
    }

    // MARK: - Rules

    /// Every rule that can be judged from one still screen.
    @MainActor
    private func judge(_ cell: String, where screen: String, step: String, app: XCUIApplication, spinner: Bool = true) {
        stepCount += 1
        shot(cell, screen, app)
        guard app.state == .runningForeground else {
            if app.state == .notRunning {
                red(cell, "crash", where: screen, step: step, detail: "the app is not running", app: app)
            }
            return
        }
        let texts = visibleTexts(app)
        if let raw = texts.first(where: { matches($0, Self.rawErrorPattern) }) {
            red(cell, "raw-error-code", where: screen, step: step, detail: "shows \"\(raw.prefix(140))\"", app: app)
        }
        if let error = texts.first(where: { matches($0, Self.errorPattern) && !matches($0, Self.errorFalsePositive) }) {
            let ways = controlLabels(app).filter { matches($0, Self.nextStepPattern) }
            if ways.isEmpty {
                red(cell, "error-without-next-step", where: screen, step: step,
                    detail: "\"\(error.prefix(120))\" with no Retry, Settings, Sign in or other way on", app: app)
            }
        }
        if spinner {
            spinnerCheck(cell, where: screen, step: step, app: app)
        }
        layoutCheck(cell, where: screen, step: step, app: app, shoot: false)
    }

    @MainActor
    private func spinnerCheck(_ cell: String, where screen: String, step: String, app: XCUIApplication) {
        let spinners = app.activityIndicators
        guard spinners.count > 0, spinners.firstMatch.exists else { return }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !spinners.allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
        }, object: nil)
        if XCTWaiter.wait(for: [gone], timeout: 20) != .completed {
            red(cell, "permanent-spinner", where: screen, step: step,
                detail: "a progress indicator is still spinning after 20 s", app: app)
        }
    }

    @MainActor
    private func layoutCheck(_ cell: String, where screen: String, step: String, app: XCUIApplication, shoot: Bool = true) {
        if shoot { shot(cell, screen, app) }
        let window = app.windows.firstMatch.frame
        guard !window.isEmpty else { return }
        var frames: [(String, CGRect)] = []
        var reported = 0
        for type in [XCUIElement.ElementType.button, .staticText, .switch, .textField] {
            let query = app.descendants(matching: type)
            for index in 0..<min(query.count, 30) where reported < 3 {
                let el = query.element(boundBy: index)
                guard el.exists else { continue }
                let frame = el.frame
                guard !frame.isEmpty, frame.intersects(window) else { continue }
                let name = el.identifier.isEmpty ? el.label : el.identifier
                // A row of a scrolling list may run past the bottom; a cut at
                // either side is a layout break.
                if frame.minX < window.minX - 1 || frame.maxX > window.maxX + 1 {
                    reported += 1
                    red(cell, "layout-break", where: screen, step: step,
                        detail: "'\(name.prefix(60))' is cut off at the side (\(Int(frame.minX))..\(Int(frame.maxX)) of \(Int(window.width)))",
                        app: app)
                }
                if type == .button, el.isHittable, frame.width > 4, frame.height > 4 {
                    frames.append((name, frame))
                }
            }
        }
        // Two tappable controls drawn on top of each other: the second can
        // never be reached by a finger.
        for i in frames.indices where reported < 3 {
            for j in frames.indices where j > i {
                let overlap = frames[i].1.intersection(frames[j].1)
                let smaller = min(frames[i].1.width * frames[i].1.height, frames[j].1.width * frames[j].1.height)
                if !overlap.isNull, smaller > 0, overlap.width * overlap.height > smaller * 0.5,
                   !frames[i].1.contains(frames[j].1), !frames[j].1.contains(frames[i].1) {
                    reported += 1
                    red(cell, "layout-break", where: screen, step: step,
                        detail: "'\(frames[i].0.prefix(40))' and '\(frames[j].0.prefix(40))' overlap", app: app)
                    break
                }
            }
        }
    }

    /// A system permission alert that showed after an action: the screen
    /// before it must have said why. Answers Don't Allow (Not Now for Face
    /// ID's own sheet) so the run never grants anything. Returns whether a
    /// permission alert showed.
    @MainActor
    @discardableResult
    private func permissionCheck(_ cell: String, where screen: String, step: String, before: String, app: XCUIApplication) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 4) else { return false }
        let label = alert.label + " " + alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        shot(cell, "\(screen)-system-prompt", app)
        let kinds: [(String, String, String)] = [
            ("notifications", #"(?i)send you notifications"#, #"(?i)notif|alert|know when|tell you"#),
            ("camera", #"(?i)access the camera|access to the camera"#, #"(?i)camera|scan|qr|photo"#),
            ("microphone", #"(?i)microphone"#, #"(?i)micro|voice|call|record|dictat|talk"#),
            ("local network", #"(?i)local network"#, #"(?i)local network|same network|this network|wi-?fi"#),
            ("Face ID", #"(?i)face id"#, #"(?i)face id|passcode|lock"#),
            ("photos", #"(?i)photos"#, #"(?i)photo|image|picture"#),
            ("speech recognition", #"(?i)speech recognition"#, #"(?i)speech|dictat|voice|transcri"#),
        ]
        let kind = kinds.first { matches(label, $0.1) }
        if let kind {
            print("FUJ " + json(["event": "prompt", "cell": cell, "where": screen, "kind": kind.0]))
            if !matches(before, kind.2) {
                red(cell, "permission-prompt-without-explanation", where: screen, step: step,
                    detail: "the \(kind.0) prompt showed with nothing on the screen before it saying why", app: app)
            }
        } else {
            note(cell, "system alert after \(step): \(label.prefix(120))")
        }
        for answer in ["Don’t Allow", "Don't Allow", "Not Now", "Cancel", "OK"] where alert.buttons[answer].exists {
            alert.buttons[answer].tap()
            break
        }
        _ = alert.waitForNonExistence(timeout: 3)
        return kind != nil
    }

    static let rawErrorPattern =
        #"Error Domain=|NS[A-Za-z]*ErrorDomain|\bcode[ =:]+-?\d{2,}|\(-?\d{3,}\)|\berrSec\w+|\b0x[0-9a-fA-F]{6,}\b|operation couldn[’']t be completed|\b[A-Z][A-Za-z]+Error\.[a-z]\w*|\bHTTP \d{3}\b|\bstatus(Code)? \d{3}\b|Optional\("#
    static let errorPattern =
        #"(?i)\b(couldn[’']t|could not|can[’']t|cannot|failed|failure|error|unable|went wrong|not connected|offline|unavailable|denied|expired|invalid|timed out|didn[’']t answer)\b"#
    /// Explanations that use error words without being an error: a setting's
    /// own description, or Help text.
    static let errorFalsePositive =
        #"(?i)^(errors that stop an agent|questions and permission requests)$|when .* (fails|is offline)|if .* (fails|can[’']t)"#
    static let nextStepPattern =
        #"(?i)retry|try again|reconnect|open settings|go to settings|sign in|log in|connect|pair|scan|learn more|help|contact|fix|turn on|enable|refresh|reload|update|continue|set up|resend|change|send again"#

    // MARK: - Dead-button walk

    /// Taps every enabled, hittable control on a screen, each from a fresh
    /// `reach()`, and judges what the tap led to: a dead button when nothing
    /// changed; otherwise the screen it opened is judged too.
    @MainActor
    private func walk(
        _ cell: String,
        where screen: String,
        reach: () -> XCUIApplication,
        skip: Set<String> = [],
        skipPrefixes: [String] = [],
        limit: Int = 14
    ) {
        if outOfTime {
            note(cell, "\(screen): not walked, the test's time budget was spent")
            return
        }
        var app = reach()
        let controls = controlKeys(in: app).filter { control in
            !skip.contains(control.key) && !skip.contains(control.label)
                && !skipPrefixes.contains { control.key.hasPrefix($0) }
        }
        shot(cell, "\(screen)-walk-start", app)
        var tapped = 0
        for (offset, control) in controls.prefix(limit).enumerated() {
            if outOfTime {
                note(cell, "\(screen): stopped after \(tapped) of \(min(controls.count, limit)) controls, the test's time budget was spent")
                break
            }
            tapped += 1
            if offset > 0 {
                app.terminate()
                app = reach()
            }
            let target = resolve(control, in: app)
            guard target.exists, target.isEnabled, target.isHittable, !target.isSelected else { continue }
            let before = signature(app)
            let beforeText = screenText(app)
            target.tap()
            stepCount += 1
            let step = "tap '\(control.label.isEmpty ? control.key : control.label)'"
            if permissionCheck(cell, where: screen, step: step, before: beforeText, app: app) { continue }
            if !waitForChange(from: before, in: app, timeout: 3) {
                red(cell, "dead-button", where: screen, step: step,
                    detail: "\(control.key) changed nothing on screen", app: app)
                continue
            }
            if app.state == .notRunning {
                red(cell, "crash", where: screen, step: step, detail: "the app stopped after the tap", app: app)
                continue
            }
            if app.state == .runningForeground {
                judge(cell, where: "\(screen)>\(control.key.prefix(40))", step: step, app: app)
            }
        }
        if controls.count > limit {
            note(cell, "\(screen) has \(controls.count) controls; the walk tapped the first \(limit)")
        }
        app.terminate()
    }

    private struct ControlKey: Hashable {
        let key: String
        let identifier: String
        let label: String
        let type: XCUIElement.ElementType
    }

    @MainActor
    private func controlKeys(in app: XCUIApplication) -> [ControlKey] {
        var seen = Set<String>()
        var out: [ControlKey] = []
        for type in [XCUIElement.ElementType.button, .link, .switch, .segmentedControl, .cell] {
            let query = app.descendants(matching: type)
            for index in 0..<min(query.count, 60) {
                let el = query.element(boundBy: index)
                guard el.exists, el.isHittable else { continue }
                let identifier = el.identifier
                let label = el.label
                let key = identifier.isEmpty ? "\(type.rawValue):\(label)" : identifier
                guard !label.isEmpty || !identifier.isEmpty, seen.insert(key).inserted else { continue }
                out.append(ControlKey(key: key, identifier: identifier, label: label, type: type))
            }
        }
        return out
    }

    @MainActor
    private func resolve(_ control: ControlKey, in app: XCUIApplication) -> XCUIElement {
        let query = app.descendants(matching: control.type)
        if !control.identifier.isEmpty {
            return query[control.identifier].firstMatch
        }
        return query.matching(NSPredicate(format: "label == %@", control.label)).firstMatch
    }

    @MainActor
    private func signature(_ app: XCUIApplication) -> String {
        guard app.state == .runningForeground else { return "state:\(app.state.rawValue)" }
        var tree = app.debugDescription
        tree = tree.replacingOccurrences(of: #"0x[0-9a-fA-F]+"#, with: "", options: .regularExpression)
        tree = tree.replacingOccurrences(of: #"\{\{[^}]*\}, \{[^}]*\}\}"#, with: "", options: .regularExpression)
        let alerts = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count
        return "\(tree)|alerts:\(alerts)"
    }

    @MainActor
    private func waitForChange(from before: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if signature(app) != before { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    // MARK: - Recording

    private func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func begin(_ cell: String) {
        stepCount = 0
        print("FUJ " + json(["event": "begin", "cell": cell]))
        if let end = Self.journeyDeadline, Date() >= end {
            note(cell, "the journey's \(Int(Self.journeyBudget / 60)) min budget was spent before this cell; it was not walked")
        }
    }

    private func finish(_ cell: String) {
        print("FUJ " + json(["event": "finish", "cell": cell, "steps": stepCount]))
    }

    private func skipCell(_ cell: String, _ detail: String) {
        print("FUJ " + json(["event": "skip", "cell": cell, "detail": detail]))
    }

    private func note(_ cell: String, _ detail: String) {
        print("FUJ " + json(["event": "note", "cell": cell, "detail": String(detail.prefix(300))]))
    }

    @MainActor
    private func red(_ cell: String, _ rule: String, where screen: String, step: String, detail: String, app: XCUIApplication) {
        let name = shot(cell, "RED-\(rule)-\(screen)", app)
        print("FUJ " + json(["event": "red", "cell": cell, "rule": rule, "where": screen, "step": String(step.prefix(120)),
                             "detail": String(detail.prefix(200)), "screenshot": name]))
    }

    /// A screenshot attachment named `fuj-NNN-<cell>-<what>`; the report finds
    /// the exported file by this name.
    @MainActor
    @discardableResult
    private func shot(_ cell: String, _ what: String, _ app: XCUIApplication) -> String {
        shotCount += 1
        let slug = "\(cell)-\(what)".replacingOccurrences(of: #"[^A-Za-z0-9.-]+"#, with: "_", options: .regularExpression)
        let name = String(format: "fuj-%03d-", shotCount) + String(slug.prefix(90))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return name
    }

    // MARK: - Helpers

    /// The mock account (DEBUG builds only), signed in past setup or signed
    /// out on sign-in, in English, never restoring the last tab.
    @MainActor
    private func launch(
        app: XCUIApplication = XCUIApplication(),
        signedIn: Bool = true,
        setupComplete: Bool = true,
        arguments: [String] = []
    ) -> XCUIApplication {
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-cmux-mobile-no-restore"]
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        if signedIn {
            app.launchArguments += ["-cmuxMobile.setupComplete", setupComplete ? "YES" : "NO"]
        } else {
            app.launchEnvironment["CMUX_MOBILE_CLEAR_AUTH"] = "1"
        }
        app.launchArguments += arguments
        app.launch()
        if signedIn && setupComplete {
            let choose = app.scrollViews["setup.teams.choose"]
            if choose.waitForExistence(timeout: 3), app.buttons["Manaflow"].exists { app.buttons["Manaflow"].tap() }
        }
        return app
    }

    /// Waits for the first paint to settle: the tab bar, a navigation bar or
    /// any button.
    @MainActor
    private func settle(_ app: XCUIApplication, timeout: TimeInterval = 8) {
        _ = waitForAny([app.tabBars.firstMatch, app.navigationBars.firstMatch, app.buttons.firstMatch], timeout: timeout)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor
    private func visibleTexts(_ app: XCUIApplication) -> [String] {
        var out: [String] = []
        let window = app.windows.firstMatch.frame
        for type in [XCUIElement.ElementType.staticText, .button, .textView, .cell] {
            let query = app.descendants(matching: type)
            for index in 0..<min(query.count, 40) {
                let el = query.element(boundBy: index)
                guard el.exists else { continue }
                if !window.isEmpty, !el.frame.intersects(window) { continue }
                let label = el.label
                if !label.isEmpty { out.append(label) }
                if type == .staticText, let value = el.value as? String, !value.isEmpty, value != label { out.append(value) }
            }
        }
        return out
    }

    @MainActor
    private func screenText(_ app: XCUIApplication) -> String {
        visibleTexts(app).joined(separator: "\n")
    }

    /// The labels of the controls a person could take as a way on. The tab
    /// bar and a navigation bar's Back are always there, so they are not one.
    @MainActor
    private func controlLabels(_ app: XCUIApplication) -> [String] {
        var chrome = Set<String>()
        for bar in [app.tabBars, app.navigationBars] {
            let buttons = bar.buttons
            for index in 0..<min(buttons.count, 20) {
                let el = buttons.element(boundBy: index)
                if el.exists { chrome.insert(el.label.isEmpty ? el.identifier : el.label) }
            }
        }
        var out: [String] = []
        for type in [XCUIElement.ElementType.button, .link] {
            let query = app.descendants(matching: type)
            for index in 0..<min(query.count, 60) {
                let el = query.element(boundBy: index)
                guard el.exists, el.isHittable else { continue }
                let name = el.label.isEmpty ? el.identifier : el.label
                if !chrome.contains(name) { out.append(name) }
            }
        }
        return out
    }

    private func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    @MainActor
    private func onScreen(_ app: XCUIApplication) -> String {
        "state \(app.state.rawValue): " + visibleTexts(app).prefix(10).joined(separator: " | ")
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in elements.contains { $0.exists } },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .slow)
        }
    }
}

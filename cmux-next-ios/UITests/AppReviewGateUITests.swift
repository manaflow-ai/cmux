import XCTest

/// App Review before Apple: the reviewer's path through the NEXT iOS app
/// (CmuxMobileApp), walked by a machine on iPhone, iPad (the iPhone app in
/// compatibility mode, where App Review also runs it) and, when the
/// simulator has it, iPhone Duo, against the commit that is about to be
/// submitted.
///
/// It runs on a Debug build with the app's mock account
/// (`CMUX_MOBILE_MOCK_AUTH`, DEBUG only): a reviewer signs in to a live
/// account, which XCUITest cannot, so the mock stands in for it. The gate
/// builds with `CMUX_MOBILE_APPLE_SIGN_IN=YES`, as the App Store
/// configurations do, so the sign-in screen is the one a reviewer sees.
///
/// Every past rejection is a test here or a rule in
/// `cmux-next-ios/scripts/app_review_gate.py` (`cmux-next-ios/AppStoreReview/rejection-history.json`
/// maps each one). Screenshots of each step are kept in the result bundle for
/// the agent reviewer pass (`cmux-next-ios/scripts/app_review_agent_pass.py`).
///
/// The dead-control walk is the detector for "the button did nothing"
/// (2.1(a), 2026-11-07): on each screen it taps every enabled, hittable
/// control from a fresh launch of that screen and requires a visible change:
/// navigation, a sheet, an alert, a state change, or the app handing off to
/// another app (a link). An option that is already selected is skipped, since
/// choosing it again changes nothing on purpose. What XCUITest cannot judge
/// is printed as a `GATE-NOTE` line, which the report lists as a warning, so
/// a gap never reads as a pass.
final class AppReviewGateUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Sign-in

    /// A signed-out fresh launch opens on sign-in with Sign in with Apple
    /// first (4.8), and every provider responds: Apple, Google and GitHub
    /// sign the mock account in, and email opens its sheet and takes a code.
    @MainActor
    func testSignInOffersAppleAndEveryProviderResponds() throws {
        let providers = ["Continue with Apple", "Continue with Google", "Continue with GitHub"]
        for provider in providers {
            let app = launch(signedIn: false)
            let button = app.buttons[provider]
            XCTAssertTrue(button.waitForExistence(timeout: 20),
                          "a signed-out launch must offer \(provider); on screen: \(onScreen(app))")
            if provider == providers[0] { capture("signin-01-welcome", app) }
            guard button.exists else {
                app.terminate()
                continue
            }
            tapWhenReady(button, in: app)
            XCTAssertTrue(waitForSignedIn(app, timeout: 15),
                          "\(provider) must sign in (mock account); on screen: \(onScreen(app))")
            capture("signin-02-\(provider.split(separator: " ").last ?? "")", app)
            app.terminate()
        }

        // Email: the sheet opens on its code step and the mock code signs in.
        let app = launch(signedIn: false, arguments: ["-cmux-mobile-email", "reviewer@example.com"])
        defer { app.terminate() }
        let field = app.textFields["Code"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "email sign-in must reach its code step; on screen: \(onScreen(app))")
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        // A fresh simulator covers its first letter keyboard with the "slide to type" tip.
        let tip = app.buttons["Continue"].firstMatch
        if tip.waitForExistence(timeout: 2) { tip.tap() }
        capture("signin-03-email-code", app)
        field.typeText("424242")
        XCTAssertTrue(waitForSignedIn(app, timeout: 15), "the email code must sign in; on screen: \(onScreen(app))")
        // Live Apple, Google and GitHub sheets are outside the app and need a
        // real account; the mock judges that each button acts, not the sheet.
        gateNote("signin-live-unjudged",
                 "the provider sheets themselves (Apple ID, Google, GitHub web sign-in) need live accounts; the mock account judged that each button signs in")
    }

    /// Sign-in: every control does something (the email sheet, a provider,
    /// a link).
    @MainActor
    func testSignInHasNoDeadControls() throws {
        let dead = walkControls(screen: "sign-in", reach: {
            let app = self.launch(signedIn: false)
            XCTAssertTrue(app.buttons["Continue with email"].waitForExistence(timeout: 20),
                          "sign-in must show; on screen: \(self.onScreen(app))")
            return app
        })
        XCTAssertTrue(dead.isEmpty, "dead controls on sign-in: \(dead.joined(separator: "; "))")
    }

    // MARK: - Onboarding

    /// The first run after sign-in, with no Mac: setup's team, Connect your
    /// Mac and notifications pages each offer a way on, and they end on Home
    /// (2.1(a)/(b), 2026-11-07: no way past the connect page).
    @MainActor
    func testOnboardingHasAWayForwardWithoutAMac() throws {
        let app = launch(setupComplete: false)
        defer { app.terminate() }
        var seen: [String] = []
        for step in 0..<8 {
            if app.tabBars.firstMatch.exists { break }
            if app.scrollViews["setup.teams.choose"].exists, app.buttons["Manaflow"].exists {
                seen.append("team")
                capture("onboarding-\(step)-team", app)
                app.buttons["Manaflow"].tap()
            } else if app.buttons["setup.pair-mac.cta"].exists {
                seen.append("pair-mac")
                capture("onboarding-\(step)-pair-mac", app)
                XCTAssertEqual(app.buttons["setup.pair-mac.cta"].label, "Not now",
                               "with no Mac online, Connect your Mac must offer Not now")
                app.buttons["setup.pair-mac.cta"].tap()
            } else if app.buttons["Not now"].exists {
                seen.append("notifications")
                capture("onboarding-\(step)-notifications", app)
                app.buttons["Not now"].tap()
            } else {
                _ = waitForAny([app.tabBars.firstMatch, app.scrollViews["setup.teams.choose"],
                                app.buttons["setup.pair-mac.cta"], app.buttons["Not now"]], timeout: 10)
            }
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10),
                      "onboarding must end on Home without a Mac (pages seen: \(seen)); on screen: \(onScreen(app))")
        if !seen.contains("pair-mac") {
            gateNote("onboarding-pair-mac-unjudged", "setup showed no Connect your Mac page with the mock account (pages seen: \(seen))")
        }
    }

    /// Onboarding: every control on its first pages does something. Sign out
    /// ends the session, so it is not tapped.
    @MainActor
    func testOnboardingHasNoDeadControls() throws {
        let dead = walkControls(screen: "onboarding", reach: {
            let app = self.launch(setupComplete: false)
            XCTAssertTrue(self.waitForAny([app.scrollViews["setup.teams.choose"], app.buttons["setup.pair-mac.cta"]], timeout: 20),
                          "onboarding must show; on screen: \(self.onScreen(app))")
            return app
        }, skip: ["setup.sign-out", "Sign out", "Sign Out"])
        XCTAssertTrue(dead.isEmpty, "dead controls in onboarding: \(dead.joined(separator: "; "))")
    }

    // MARK: - Home and Chief

    /// Signed in with no Mac, the reviewer lands on Home, and Home shows the
    /// Cloud Chief, which needs no Mac (the 2026-10 and 2026-11-07
    /// rejections: features unreachable without a Mac).
    @MainActor
    func testSignedInReviewerReachesHomeWithoutAMac() throws {
        let app = launch(arguments: ["-cmux-mobile-tab", "home"])
        defer { app.terminate() }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "the shell must show; on screen: \(onScreen(app))")
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(home.exists, "the tab bar must have Home")
        XCTAssertTrue(home.isSelected, "a launch on Home must show Home")
        capture("home-01", app)
        for tab in ["Workspaces", "Feed", "Settings", "Home"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.exists, "the tab bar must have \(tab); on screen: \(onScreen(app))")
            guard button.exists else { continue }
            button.tap()
            XCTAssertTrue(button.isSelected, "\(tab) must open when tapped")
            capture("home-02-tab-\(tab)", app)
        }
        let chief = element("home.chief", in: app)
        let macChief = element("home.chief.mac", in: app)
        XCTAssertTrue(waitForAny([chief, macChief], timeout: 20),
                      "Home must show Chief with no Mac paired; on screen: \(onScreen(app))")
    }

    /// Chief opens from Home and a message sends; with the mock Chief a reply
    /// shows.
    @MainActor
    func testChiefOpensAndAMessageSendsWithAReply() throws {
        var app = launch(arguments: ["-cmux-mobile-tab", "home"])
        defer { app.terminate() }
        let chief = element("home.chief", in: app)
        let macChief = element("home.chief.mac", in: app)
        let field = app.textViews["conversation.composer.text"]
        if waitForAny([chief, macChief], timeout: 20) {
            tapWhenReady(chief.exists ? chief : macChief, in: app)
        } else {
            // Home did not list Chief (the Home test fails for that); judge
            // the conversation itself from its own launch.
            gateNote("chief-from-home-unjudged", "Home listed no Chief row, so Chief was opened with -cmux-mobile-demo chief-open")
            app.terminate()
            app = launch(arguments: ["-cmux-mobile-demo", "chief-open"])
        }
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Chief must open with a message box; on screen: \(onScreen(app))")
        capture("chief-01-open", app)
        guard field.exists else { return }
        let messages = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "conversation.message."))
        // The seeded history settles before the count is read.
        _ = messages.firstMatch.waitForExistence(timeout: 10)
        let before = messages.count
        field.tap()
        field.typeText("App Review check: hello")
        let send = app.buttons["conversation.composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Chief must have a Send button")
        XCTAssertTrue(send.isEnabled, "Send must be enabled with a draft")
        send.tap()
        capture("chief-02-sent", app)
        let sent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in messages.count >= before + 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 10), .completed, "the sent message must show; on screen: \(onScreen(app))")
        // The mock Chief reads, types, then replies within about 4 s.
        let replied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in messages.count >= before + 2 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [replied], timeout: 20), .completed,
                       "Chief's reply must show after a send (mock Chief); on screen: \(onScreen(app))")
        capture("chief-03-reply", app)
        gateNote("chief-live-reply-unjudged", "the reply came from the mock Chief; a live Chief reply needs the reviewer's live account")
    }

    /// Home: every control does something. Destructive row actions are not
    /// tapped.
    @MainActor
    func testHomeHasNoDeadControls() throws {
        let dead = walkControls(screen: "home", reach: {
            let app = self.launch(arguments: ["-cmux-mobile-tab", "home"])
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "the shell must show; on screen: \(self.onScreen(app))")
            return app
        }, skip: ["home.row.delete"], skipPrefixes: ["home.row.swipe."])
        XCTAssertTrue(dead.isEmpty, "dead controls on Home: \(dead.joined(separator: "; "))")
    }

    // MARK: - Settings

    /// Settings: every control does something. Sign out, Delete Account and
    /// Remove This iPhone end the session or the account, so the walk does not
    /// tap them; Delete Account is judged on its own below.
    @MainActor
    func testSettingsHaveNoDeadControls() throws {
        let destructive: Set<String> = ["settings.logout", "settings.deleteAccount", "settings.removeThisPhone",
                                        "settings.developer.mock", "Quit to apply"]
        let settings: () -> XCUIApplication = {
            let app = self.launch(arguments: ["-cmux-mobile-tab", "settings"])
            XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 30),
                          "Settings must show; on screen: \(self.onScreen(app))")
            return app
        }
        // The walk taps what is on screen, so Settings is walked at the top
        // and again scrolled to the bottom.
        var dead = walkControls(screen: "settings", reach: settings, skip: destructive)
        dead += walkControls(screen: "settings-bottom", reach: {
            let app = settings()
            for _ in 0..<6 { app.swipeUp(velocity: .fast) }
            return app
        }, skip: destructive)
        dead += walkControls(screen: "settings-account", reach: {
            let app = self.launch(arguments: ["-cmux-mobile-tab", "settings", "-cmux-mobile-settings-page", "account"])
            XCTAssertTrue(app.buttons["settings.deleteAccount"].waitForExistence(timeout: 30),
                          "Account must show; on screen: \(self.onScreen(app))")
            return app
        }, skip: ["settings.logout", "settings.deleteAccount"])
        XCTAssertTrue(dead.isEmpty, "dead controls in Settings: \(dead.joined(separator: "; "))")
    }

    /// Delete Account is in the app (5.1.1(v)) and asks before it deletes.
    /// The gate never confirms it.
    @MainActor
    func testDeleteAccountAsksAndIsNotTappedThrough() throws {
        let app = launch(arguments: ["-cmux-mobile-tab", "settings", "-cmux-mobile-settings-page", "account"])
        defer { app.terminate() }
        let delete = app.buttons["settings.deleteAccount"]
        scrollTo(delete, in: app)
        XCTAssertTrue(delete.waitForExistence(timeout: 30),
                      "Settings > Account must offer Delete Account (5.1.1(v)); on screen: \(onScreen(app))")
        guard delete.exists else { return }
        delete.tap()
        let ask = app.staticTexts["Delete your cmux account?"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5), "Delete Account must ask before it deletes; on screen: \(onScreen(app))")
        capture("settings-delete-account-asks", app)
        // Cancel, never the destructive button.
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }
        XCTAssertTrue(ask.waitForNonExistence(timeout: 5), "the deletion dialog must close on Cancel")
        XCTAssertTrue(delete.exists, "cancelling must leave the account in place")
        gateNote("delete-account-unconfirmed", "Delete Account was not confirmed (it would delete the account); the deletion itself is unjudged")
    }

    // MARK: - Hostile conditions

    /// Camera denied: Scan QR on your Mac must explain and offer a way on,
    /// never do nothing (the 2026-11-07 Scan Pairing Code rejection's class).
    @MainActor
    func testScanWithCameraDeniedExplainsInsteadOfDoingNothing() throws {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .camera)
        addUIInterruptionMonitor(withDescription: "camera") { alert in
            for label in ["Don’t Allow", "Don't Allow"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        let launched = launch(app: app, arguments: ["-cmux-mobile-tab", "settings", "-cmux-mobile-settings-page", "devices"])
        defer { launched.terminate() }
        let scan = launched.buttons["settings.scanMacCode"]
        guard scan.waitForExistence(timeout: 20) else {
            gateNote("scan-unjudged", "Settings > Devices showed no Scan QR on your Mac with the mock account, so the camera-denied path was not walked")
            return
        }
        scan.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Don’t Allow", "Don't Allow"] where springboard.buttons[label].waitForExistence(timeout: 4) {
            springboard.buttons[label].tap()
        }
        launched.tap()
        let explained = launched.staticTexts["Camera access is off"]
        XCTAssertTrue(explained.waitForExistence(timeout: 8),
                      "Scan with the camera denied must explain; on screen: \(onScreen(launched))")
        XCTAssertTrue(launched.buttons["Open Settings"].exists, "the camera-denied page must offer Open Settings")
        capture("hostile-01-camera-denied", launched)
    }

    /// Rotation with Chief open and an unsent draft: the conversation, the
    /// draft and the layout survive every size-class change, and nothing lands
    /// outside the window. Then Settings. XCUITest cannot fold a simulator,
    /// so on iPhone Duo the fold itself is a GATE-NOTE.
    @MainActor
    func testSizeClassChangesKeepStateAndLayout() throws {
        var app = launch(arguments: ["-cmux-mobile-demo", "chief-open"])
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        let orientations: [UIDeviceOrientation] = [.landscapeLeft, .portrait, .landscapeRight, .portrait]
        let field = app.textViews["conversation.composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Chief must open; on screen: \(onScreen(app))")
        let draft = "size class draft"
        if field.exists {
            field.tap()
            field.typeText(draft)
        }
        for (step, orientation) in orientations.enumerated() {
            XCUIDevice.shared.orientation = orientation
            _ = field.waitForExistence(timeout: 2)
            capture("size-chief-\(step)-\(orientation.rawValue)", app)
            XCTAssertTrue(field.exists, "Chief must survive a size change (step \(step)); on screen: \(onScreen(app))")
            XCTAssertTrue((field.value as? String)?.contains(draft) == true,
                          "the draft must survive a size change (step \(step)), got \(String(describing: field.value))")
            assertNothingOffscreen(app, step: "size-chief-\(step)")
        }

        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        app = launch(arguments: ["-cmux-mobile-tab", "settings"])
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 30), "Settings must open; on screen: \(onScreen(app))")
        for (step, orientation) in orientations.enumerated() {
            XCUIDevice.shared.orientation = orientation
            _ = settingsTab.waitForExistence(timeout: 2)
            capture("size-settings-\(step)-\(orientation.rawValue)", app)
            XCTAssertTrue(settingsTab.exists && settingsTab.isSelected,
                          "Settings must survive a size change (step \(step)); on screen: \(onScreen(app))")
            assertNothingOffscreen(app, step: "size-settings-\(step)")
        }

        // UIDevice.name is generic since iOS 16; the simulator names itself.
        let device = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        if device.localizedCaseInsensitiveContains("Duo") {
            gateNote("fold-unjudged", "XCUITest cannot fold the simulator; fold and unfold were not walked on \(device)")
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            gateNote("ipad-multitasking-unjudged",
                     "XCUITest cannot drive Split View or Stage Manager; the iPhone app was judged full screen on iPad")
        }
    }

    /// The largest accessibility text size: sign-in and Settings keep every
    /// control on screen and reachable. (Leo, 2026-11-10: anticipate Dynamic
    /// Type sizes and dark mode.)
    @MainActor
    func testLargestTextSizeKeepsEveryControlReachable() throws {
        let xxxl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        var app = launch(signedIn: false, arguments: xxxl)
        let email = app.buttons["Continue with email"]
        XCTAssertTrue(email.waitForExistence(timeout: 20), "sign-in must show; on screen: \(onScreen(app))")
        capture("type-xxxl-signin", app)
        for label in ["Continue with Apple", "Continue with Google", "Continue with GitHub", "Continue with email"] {
            let button = app.buttons[label]
            scrollTo(button, in: app)
            XCTAssertTrue(button.exists && button.isHittable, "\(label) must stay reachable at the largest text size")
        }
        assertNothingOffscreen(app, step: "type-xxxl-signin")
        app.terminate()

        app = launch(arguments: xxxl + ["-cmux-mobile-tab", "settings"])
        defer { app.terminate() }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "Settings must open; on screen: \(onScreen(app))")
        capture("type-xxxl-settings", app)
        assertNothingOffscreen(app, step: "type-xxxl-settings")
        let logout = app.buttons["settings.logout"]
        scrollTo(logout, in: app)
        XCTAssertTrue(logout.exists && logout.isHittable, "Sign out must stay reachable at the largest text size")
        capture("type-xxxl-settings-bottom", app)
    }

    // MARK: - Dead-control walker

    /// Taps every enabled, hittable control on a screen, each from a fresh
    /// `reach()`, and returns the ones that changed nothing.
    @MainActor
    private func walkControls(
        screen: String,
        reach: () -> XCUIApplication,
        skip: Set<String> = [],
        skipPrefixes: [String] = [],
        limit: Int = 40
    ) -> [String] {
        var app = reach()
        let controls = controlKeys(in: app).filter { control in
            !skip.contains(control.key) && !skip.contains(control.label)
                && !skipPrefixes.contains { control.key.hasPrefix($0) }
        }
        capture("walk-\(screen)-start", app)
        var dead: [String] = []
        var disabledWithoutReason: [String] = []
        for (offset, control) in controls.prefix(limit).enumerated() {
            if offset > 0 {
                app.terminate()
                app = reach()
            }
            let target = resolve(control, in: app)
            guard target.exists else { continue }
            if !target.isEnabled {
                let reason = (target.value as? String).map { !$0.isEmpty } ?? false
                if !reason && target.label.isEmpty {
                    disabledWithoutReason.append(control.key)
                }
                continue
            }
            guard target.isHittable else { continue }
            // Choosing the option that is already chosen (the selected tab, a
            // checked picker row) changes nothing on purpose; its siblings are
            // what the walk judges.
            if target.isSelected { continue }
            let before = signature(app)
            target.tap()
            let changed = waitForChange(from: before, in: app, timeout: 3)
            if !changed {
                dead.append("\(screen): \(control.key)")
                capture("walk-\(screen)-DEAD-\(control.key)", app)
            }
        }
        if controls.count > limit {
            gateNote("walk-\(screen)-truncated", "\(screen) has \(controls.count) controls; the walk tapped the first \(limit)")
        }
        app.terminate()
        if !disabledWithoutReason.isEmpty {
            // A disabled control with no stated reason reads as broken to a
            // reviewer. Reported, not failed: some are legitimately idle.
            let note = XCTAttachment(string: disabledWithoutReason.joined(separator: "\n"))
            note.name = "walk-\(screen)-disabled-without-reason"
            note.lifetime = .keepAlways
            add(note)
        }
        return dead
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
                guard !key.isEmpty, !label.isEmpty || !identifier.isEmpty, seen.insert(key).inserted else { continue }
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

    /// What a person would see change: the element tree minus frames and
    /// addresses, the app's state (a link opens Safari), and springboard alerts.
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

    // MARK: - Helpers

    /// The mock account (DEBUG builds only), signed in past setup or signed
    /// out on sign-in, in English, never restoring the last tab.
    @MainActor
    private func launch(
        app: XCUIApplication = XCUIApplication(),
        signedIn: Bool = true,
        setupComplete: Bool = true,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-cmux-mobile-no-restore"]
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        if signedIn {
            app.launchArguments += ["-cmuxMobile.setupComplete", setupComplete ? "YES" : "NO"]
        } else {
            app.launchEnvironment["CMUX_MOBILE_CLEAR_AUTH"] = "1"
        }
        app.launchArguments += arguments
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        if signedIn && setupComplete {
            // The first mock run may still ask for a team.
            let choose = app.scrollViews["setup.teams.choose"]
            if choose.waitForExistence(timeout: 3), app.buttons["Manaflow"].exists { app.buttons["Manaflow"].tap() }
        }
        capture("launch-\(signedIn ? "signed-in" : "signed-out")", app)
        return app
    }

    /// Signed in: the shell's tab bar, or setup's team picker (the step after
    /// sign-in on a first run).
    @MainActor
    private func waitForSignedIn(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitForAny([app.tabBars.firstMatch, app.scrollViews["setup.teams.choose"]], timeout: timeout)
    }

    /// What the reviewer would see, short enough for a failure message: the
    /// app state, any system alert, and the first labelled elements.
    @MainActor
    private func onScreen(_ app: XCUIApplication) -> String {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alerts = springboard.alerts.allElementsBoundByIndex.map(\.label)
        let lines = app.debugDescription
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let range = line.range(of: "identifier: '") ?? line.range(of: "label: '") else { return nil }
                return String(line[range.lowerBound...].prefix(60))
            }
        return "state \(app.state.rawValue), alerts \(alerts), elements \(lines.prefix(14).joined(separator: " | "))"
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func tapWhenReady(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "missing \(element.description)")
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    @MainActor
    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in elements.contains { $0.exists } },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Something the walk could not judge. The report lists every note as a
    /// warning (it reads the `GATE-NOTE` lines from the suite log), so a gap
    /// never reads as a pass.
    @MainActor
    private func gateNote(_ name: String, _ message: String) {
        let note = XCTAttachment(string: "\(name): \(message)")
        note.name = "gate-note-\(name)"
        note.lifetime = .keepAlways
        add(note)
        print("GATE-NOTE \(name): \(message)")
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .slow)
        }
    }

    @MainActor
    private func assertNothingOffscreen(_ app: XCUIApplication, step: String) {
        let window = app.windows.firstMatch.frame
        guard !window.isEmpty else { return }
        let buttons = app.buttons
        for index in 0..<min(buttons.count, 40) {
            let button = buttons.element(boundBy: index)
            guard button.exists, button.isHittable else { continue }
            let frame = button.frame
            // A row of a scrolling list may run past the bottom edge; a
            // control cut off at the sides is a layout glitch.
            XCTAssertTrue(
                frame.minX >= window.minX - 1 && frame.maxX <= window.maxX + 1 && frame.intersects(window),
                "\(step): \(button.identifier.isEmpty ? button.label : button.identifier) is outside the window \(frame) vs \(window)"
            )
        }
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "gate-\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

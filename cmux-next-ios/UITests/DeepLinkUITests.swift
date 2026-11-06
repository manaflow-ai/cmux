import XCTest

/// cmux links open what they name (verify/deep-links.md), on mock data: the sample
/// workspaces carry Mac-style ids (`AppStore.mockLinkIDs`): workspace n is
/// `ws_` + n in 32 hex digits, its tab m is `tab_` + (16n + m).
///
/// - opened by the system (as Messages, Notes or a QR code open them),
/// - from Safari: cmux.com's live agent-link page and its Open in cmux button,
/// - tapped inside the app: a link in an agent's answer.
///
/// Each step attaches a screenshot; the fleet step records the screen as it runs.
final class DeepLinkUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    static func id(_ prefix: String, _ number: Int) -> String { prefix + String(format: "%032x", number) }

    @MainActor
    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "shell\n\(app.debugDescription)")
        return app
    }

    @MainActor
    func expectWorkspace(_ app: XCUIApplication, _ id: String, showing title: String?, _ step: String) {
        let page = app.descendants(matching: .any)["workspace.\(id)"]
        XCTAssertTrue(page.waitForExistence(timeout: 15), "\(step): workspace \(id)\n\(app.debugDescription)")
        // The page's bottom pill names the tab on screen (an agent tab by its task).
        if let title {
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 10), "\(step): tab \(title)\n\(app.debugDescription)")
        }
        attach(app, step)
    }

    /// The system opens each kind of link (`simctl openurl`, Messages, Notes, a QR code).
    @MainActor
    func testLinksOpenedBySystemOpenWhatTheyName() throws {
        let app = launch()
        attach(app, "01-launched")
        // A tab link: ws-ios (workspace 3), its first tab, xcodebuild.
        app.open(URL(string: "cmux://tab/\(Self.id("tab_", 48))")!)
        expectWorkspace(app, "ws-ios", showing: "xcodebuild", "02-tab-link")
        // A workspace link in a Mac dev build's scheme: ws-web (workspace 2).
        app.open(URL(string: "cmux-dev://workspace/\(Self.id("ws_", 2))")!)
        expectWorkspace(app, "ws-web", showing: nil, "03-workspace-link")
        // An agent link: the Claude tab of ws-cmux (workspace 1) runs harness session mock-t-claude.
        app.open(URL(string: "cmux://agent/claude/mock-t-claude?host=mac-studio")!)
        expectWorkspace(app, "ws-cmux", showing: "Refactor transport layer", "04-agent-link")
        // A Home conversation link opens Chief.
        app.open(URL(string: "cmux://conversation/home/message/m1")!)
        // The Chief conversation is pushed on Home and hides the tab bar.
        let tabBarGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.tabBars.firstMatch)
        wait(for: [tabBarGone], timeout: 15)
        attach(app, "05-conversation-link")
        // A link to nothing the phone lists says so and stays put.
        app.open(URL(string: "cmux://tab/\(Self.id("tab_", 0xffff))")!)
        XCTAssertTrue(app.staticTexts["Couldn't find that link on your Macs."].waitForExistence(timeout: 15), "toast\n\(app.debugDescription)")
        attach(app, "06-unknown-link")
    }

    /// From Safari: cmux.com's agent link page (live) hands off with its Open in cmux button.
    @MainActor
    func testSafariOpenInCmuxOpensTheAgent() throws {
        let app = launch()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.open(URL(string: "https://cmux.com/deeplink/agent?harness=claude&session=mock-t-ios-claude&host=mac-studio")!)
        let button = safari.links["Open in cmux"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 30), "Open in cmux\n\(safari.debugDescription)")
        attach(safari, "07-safari-agent-page")
        button.tap()
        // iOS asks before Safari hands a link to an app.
        let open = safari.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 10) {
            attach(safari, "08-safari-open-prompt")
            open.tap()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "cmux in front")
        // ws-ios's Claude tab runs harness session mock-t-ios-claude.
        expectWorkspace(app, "ws-ios", showing: "Redesign the workspaces list", "09-from-safari")
    }

    /// Tapped inside the app: a cmux link in an agent's answer opens its tab, not Safari.
    @MainActor
    func testLinkTappedInAChatOpensInTheApp() throws {
        // Another test may have left Safari running in the background.
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        let app = launch()
        // ws-cmux's Claude chat (tab 16): its history's answer links ws-ios's xcodebuild tab.
        app.open(URL(string: "cmux://tab/\(Self.id("tab_", 16))")!)
        let page = app.descendants(matching: .any)["workspace.ws-cmux"]
        XCTAssertTrue(page.waitForExistence(timeout: 15), "ws-cmux\n\(app.debugDescription)")
        let link = app.links["the xcodebuild tab"].firstMatch
        for _ in 0..<12 where !link.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(link.waitForExistence(timeout: 10), "link\n\(app.debugDescription)")
        // Bring it clear of the status bar before the tap.
        if link.frame.minY < 200 {
            let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: 300 - link.frame.minY)))
        }
        attach(app, "10-chat-with-link")
        link.tap()
        XCTAssertEqual(safari.state, .notRunning, "Safari stayed closed")
        expectWorkspace(app, "ws-ios", showing: "xcodebuild", "11-chat-link-opened")
    }

    /// Settings → About: Terms of Use, Privacy Policy and Help open their live cmux.com pages.
    @MainActor
    func testLegalLinksOpenTheirLivePages() throws {
        let app = launch()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        app.tabBars.buttons["Settings"].tap()
        for (row, heading, step) in [("Terms of Use", "Terms of Service", "12-terms"), ("Privacy Policy", "Privacy Policy", "13-privacy"),
                                     ("Help", "docs", "14-help")] {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", row)).firstMatch
            for _ in 0..<8 where !button.isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(button.waitForExistence(timeout: 10), "\(row)\n\(app.debugDescription)")
            button.tap()
            XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "\(row): Safari")
            let page = safari.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", heading)).firstMatch
            XCTAssertTrue(page.waitForExistence(timeout: 30), "\(row): \(heading)\n\(safari.debugDescription)")
            XCTAssertFalse(safari.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] '404'")).firstMatch.exists, "\(row): 404")
            attach(safari, step)
            app.activate()
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        print("CMUX_MOBILE_UI_STEP \(name)")
    }
}

import XCTest

/// A focused screen (a workspace and its tab, a chat, a conversation) never shows the root
/// tab bar, whichever way it was opened, and the bar comes back on the tab's root. Every entry
/// path, repeated, against mock data:
///
/// - a cmux link from each root tab and from inside another workspace (notification taps open
///   through the same router and `ShellModel.open(target:)`),
/// - a row tap on Workspaces, then the composer's keyboard, the app sent to the background and
///   back, and an edge swipe let go early (the pop cancels),
/// - a Feed row (its chat) and the Chief row on Home,
/// - the launch restore of the last workspace.
///
/// Each check prints a `CMUX_FOCUS_TABBAR` line; a failure attaches the screen.
final class FocusedTabBarUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// How long a check waits for the bar to go (or, on a root, to come back). The bug is a bar
    /// that stays: on the base it never leaves. One accessibility snapshot of a busy app (a
    /// streaming agent tab) took 14-31 s on the fleet, so a wait can end with its query still
    /// pending: a final read decides.
    static let settle: TimeInterval = 45

    static func id(_ prefix: String, _ number: Int) -> String { prefix + String(format: "%032x", number) }

    /// Mock links (`AppStore.mockLinkIDs`): workspace n is `ws_` + n, its tab m is `tab_` + (16n + m).
    static let links: [(url: String, workspace: String)] = [
        ("cmux://tab/\(id("tab_", 48))", "ws-ios"),
        ("cmux-dev://workspace/\(id("ws_", 2))", "ws-web"),
        ("cmux://agent/claude/mock-t-claude?host=mac-studio", "ws-cmux"),
    ]

    @MainActor
    func launch(restore: Bool = false, tab: String? = "home") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        if let tab { app.launchArguments += ["-cmux-mobile-tab", tab] }
        if !restore { app.launchArguments += ["-cmux-mobile-no-restore"] }
        // The app's DEBUG tab bar probe: the real UITabBar's state, not the accessibility tree's.
        app.launchArguments += ["-cmux-mobile-tabbar-probe"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        return app
    }

    // MARK: Checks

    /// `page` is on screen and the tab bar is gone, and stays gone.
    @MainActor
    func expectFocused(_ app: XCUIApplication, _ page: String, _ step: String) {
        let shown = app.descendants(matching: .any)[page].waitForExistence(timeout: 15)
        XCTAssertTrue(shown, "\(step): \(page) not shown")
        expectBarGone(app, step, over: page, pageShown: shown)
    }

    /// Both views of the bar say it is gone, within `settle`, and it does not come back:
    /// - the probe: the real UITabBar is not drawn (hidden by its controller, or a view of it hidden),
    /// - the accessibility tree: VoiceOver cannot reach its buttons.
    @MainActor
    func expectBarGone(_ app: XCUIApplication, _ step: String, over page: String, pageShown: Bool = true) {
        let probe = Self.probe(app)
        let bar = app.tabBars.firstMatch
        let drawnGone = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "value BEGINSWITH 'gone'"), evaluatedWith: probe)],
                                         timeout: Self.settle) == .completed
            || ((probe.value as? String)?.hasPrefix("gone") ?? false)
        let axGone = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: bar)], timeout: 5) == .completed
            || !bar.exists
        // Never back while the screen stays up: a bar that returns after a moment is the same bug.
        let back = drawnGone && XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "value BEGINSWITH 'drawn'"), evaluatedWith: probe)],
                                                 timeout: 1.5) == .completed
        let state = (probe.value as? String) ?? "no probe"
        let ok = pageShown && drawnGone && axGone && !back
        print("CMUX_FOCUS_TABBAR \(step) \(page): \(ok ? "ok" : "TAB BAR SHOWN") [\(state)]")
        XCTAssertTrue(drawnGone, "\(step): the tab bar is drawn over \(page) [\(state)]")
        XCTAssertTrue(axGone, "\(step): VoiceOver reaches the tab bar over \(page)")
        XCTAssertFalse(back, "\(step): the tab bar came back over \(page)")
        attach(app, ok ? step : "FAIL-\(step)")
    }

    /// A tab root: the bar is drawn, VoiceOver and touches reach it, and its buttons answer.
    @MainActor
    func expectRoot(_ app: XCUIApplication, _ step: String) {
        let probe = Self.probe(app)
        let drawn = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "value MATCHES '^drawn .* ax=1 touch=1 .*'"), evaluatedWith: probe)],
                                     timeout: Self.settle) == .completed
            || ((probe.value as? String)?.range(of: "^drawn .* ax=1 touch=1 ", options: .regularExpression)) != nil
        let button = app.tabBars.buttons["Workspaces"]
        let ok = drawn && button.waitForExistence(timeout: 10) && button.isHittable
        print("CMUX_FOCUS_TABBAR \(step) root: \(ok ? "ok" : "NO TAB BAR") [\((probe.value as? String) ?? "no probe")]")
        XCTAssertTrue(ok, "\(step): no working tab bar on the root")
        if !ok { attach(app, "FAIL-\(step)") }
    }

    /// The window's tab bar probe (`TabBarProbe`).
    @MainActor
    static func probe(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["shell.tabbar.probe"].firstMatch
    }

    // MARK: Gestures

    /// The system edge swipe back. `commit: false` lets go a quarter of the way, slowly: the pop cancels.
    @MainActor
    func edgeSwipe(_ app: XCUIApplication, commit: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: commit ? 0.9 : 0.25, dy: 0.45))
        if commit {
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        } else {
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        }
    }

    /// Back to the Workspaces list from a workspace: the edge swipe, else the page's Back.
    @MainActor
    func leaveWorkspace(_ app: XCUIApplication) {
        edgeSwipe(app, commit: true)
        if app.tabBars.firstMatch.waitForExistence(timeout: 3) { return }
        let back = app.buttons["Back"].firstMatch
        if back.exists, back.isEnabled { back.tap() } else { print("CMUX_FOCUS_TABBAR leave workspace: no way back (swipe and Back)") }
    }

    @MainActor
    func select(_ app: XCUIApplication, _ tab: String) {
        let button = app.tabBars.buttons[tab]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "tab \(tab)")
        button.tap()
    }

    // MARK: Paths

    /// A link opens its workspace from every root tab and over another workspace (the
    /// reported bug: Home, `cmux://tab/…`, the workspace shown over the bar).
    @MainActor
    func testLinksFromEveryTabNeverShowTheTabBar() {
        let app = launch()
        expectRoot(app, "launch")
        for round in 1...3 {
            for (index, origin) in ["Home", "Feed", "Settings", "Workspaces"].enumerated() {
                let link = Self.links[(round + index) % Self.links.count]
                select(app, origin)
                app.open(URL(string: link.url)!)
                expectFocused(app, "workspace.\(link.workspace)", "r\(round)-link-from-\(origin)")
                // A second link while a workspace is up: its stack is rebuilt.
                let next = Self.links[(round + index + 1) % Self.links.count]
                app.open(URL(string: next.url)!)
                expectFocused(app, "workspace.\(next.workspace)", "r\(round)-link-over-workspace-from-\(origin)")
                leaveWorkspace(app)
                expectRoot(app, "r\(round)-back-from-\(origin)")
            }
        }
        attach(app, "links-end")
    }

    /// Row taps, then the keyboard, background and foreground, and a cancelled edge swipe, inside the workspace.
    @MainActor
    func testRowTapKeyboardBackgroundAndCancelledSwipe() {
        let app = launch(tab: "workspaces")
        for round in 1...4 {
            let workspace = ["ws-cmux", "ws-web", "ws-ios"][round % 3]
            let row = app.buttons["workspace.row.\(workspace)"]
            XCTAssertTrue(row.waitForExistence(timeout: 15), "row \(workspace)")
            row.tap()
            let page = "workspace.\(workspace)"
            expectFocused(app, page, "r\(round)-row-tap")
            // The keyboard: the page's composer field, when the tab has one.
            let field = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
            if field.exists, field.isHittable {
                field.tap()
                if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
                    field.typeText("ls")
                    expectFocused(app, page, "r\(round)-keyboard-up")
                    app.swipeDown(velocity: .fast)
                    expectFocused(app, page, "r\(round)-keyboard-down")
                } else {
                    print("CMUX_FOCUS_TABBAR r\(round)-keyboard \(page): SKIPPED (no keyboard)")
                }
            } else {
                print("CMUX_FOCUS_TABBAR r\(round)-keyboard \(page): SKIPPED (no composer field)")
            }
            XCUIDevice.shared.press(.home)
            app.activate()
            expectFocused(app, page, "r\(round)-background-foreground")
            edgeSwipe(app, commit: false)
            expectFocused(app, page, "r\(round)-cancelled-swipe")
            leaveWorkspace(app)
            expectRoot(app, "r\(round)-back")
        }
        attach(app, "rows-end")
    }

    /// A Feed row opens its chat; the Chief row on Home its conversation.
    @MainActor
    func testFeedChatAndHomeConversation() {
        let app = launch(tab: "feed")
        for round in 1...3 {
            select(app, "Feed")
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'feed.row.'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), "feed row")
            // The row's header line (agent and time): its middle can be a question's options.
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).tap()
            expectFocusedWithoutPage(app, "r\(round)-feed-chat")
            edgeSwipe(app, commit: true)
            expectRoot(app, "r\(round)-feed-back")
            select(app, "Home")
            app.open(URL(string: "cmux://conversation/home/message/m1")!)
            expectFocusedWithoutPage(app, "r\(round)-home-conversation")
            edgeSwipe(app, commit: true)
            if !app.tabBars.firstMatch.waitForExistence(timeout: 3) {
                // Chief's page hides the navigation bar: its own back control.
                let back = app.buttons["Back"].firstMatch
                if back.exists { back.tap() } else { print("CMUX_FOCUS_TABBAR r\(round)-home-back: no way back (swipe and Back)") }
            }
            expectRoot(app, "r\(round)-home-back")
        }
    }

    /// The launch restore puts the last workspace back, switching from the first tab at launch.
    @MainActor
    func testLaunchRestoreNeverShowsTheTabBar() {
        for round in 1...3 {
            let workspace = ["ws-cmux", "ws-web", "ws-ios"][round % 3]
            let app = launch(tab: "workspaces")
            let row = app.buttons["workspace.row.\(workspace)"]
            XCTAssertTrue(row.waitForExistence(timeout: 15), "row \(workspace)")
            row.tap()
            expectFocused(app, "workspace.\(workspace)", "r\(round)-before-relaunch")
            app.terminate()
            let restored = launch(restore: true, tab: nil)
            expectFocused(restored, "workspace.\(workspace)", "r\(round)-restored")
            restored.terminate()
        }
    }

    /// A slow edge swipe back from a workspace, held halfway, then let go: the list comes back
    /// with its tab bar (the recording shows how the bar returns).
    @MainActor
    func testSlowSwipeBackReturnsTheTabBar() {
        let app = launch(tab: "workspaces")
        for round in 1...2 {
            let row = app.buttons["workspace.row.ws-cmux"]
            XCTAssertTrue(row.waitForExistence(timeout: 15), "row ws-cmux")
            row.tap()
            expectFocused(app, "workspace.ws-cmux", "r\(round)-slow-swipe-open")
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
            let half = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: half, withVelocity: .slow, thenHoldForDuration: 1.5)
            expectRoot(app, "r\(round)-slow-swipe-back")
        }
    }

    /// Pages pushed inside a focused screen keep the bar hidden: the page menu's pages when the
    /// workspace lists them (Search Agent Chats, Screens, Panes), the agent tab's diff, Chief's
    /// info. Then a link to Home's conversation while a workspace is up, Home's root (bar shown),
    /// and Workspaces selected again (its workspace with the bar hidden, or its list with it shown).
    @MainActor
    func testPagesPushedInsideAFocusedScreen() {
        let app = launch(tab: "workspaces")
        for round in 1...2 {
            select(app, "Workspaces")
            let row = app.buttons["workspace.row.ws-cmux"]
            XCTAssertTrue(row.waitForExistence(timeout: 15), "row ws-cmux")
            row.tap()
            expectFocused(app, "workspace.ws-cmux", "r\(round)-inner-open")
            var opened = 0
            for title in ["Search Agent Chats", "Screens", "Panes"] {
                let menu = app.buttons["Page Menu"].firstMatch
                guard menu.waitForExistence(timeout: 5), menu.isHittable else { break }
                menu.tap()
                let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
                guard item.waitForExistence(timeout: 3) else {
                    print("CMUX_FOCUS_TABBAR r\(round)-inner \(title): SKIPPED (not in the mock page menu)")
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
                    continue
                }
                item.tap()
                expectFocusedWithoutPage(app, "r\(round)-inner-\(title)")
                opened += 1
                edgeSwipe(app, commit: true)
                expectFocused(app, "workspace.ws-cmux", "r\(round)-inner-\(title)-back")
            }
            // The agent tab's change summary pushes the diff inside the workspace (mock data has no
            // Screens, Panes or agent chats in the page menu): this page must open.
            let review = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Review'")).firstMatch
            XCTAssertTrue(review.waitForExistence(timeout: 10), "r\(round): no Review in the agent tab")
            if review.exists {
                review.tap()
                expectFocusedWithoutPage(app, "r\(round)-inner-diff")
                opened += 1
                edgeSwipe(app, commit: true)
                expectFocused(app, "workspace.ws-cmux", "r\(round)-inner-diff-back")
            }
            XCTAssertGreaterThan(opened, 0, "no page opened inside the workspace")
            // Another tab's conversation over the open workspace, then Chief's info inside it.
            app.open(URL(string: "cmux://conversation/home/message/m1")!)
            expectFocusedWithoutPage(app, "r\(round)-cross-tab-conversation")
            let info = app.buttons["Chief"].firstMatch
            if info.waitForExistence(timeout: 5), info.isHittable {
                info.tap()
                expectFocusedWithoutPage(app, "r\(round)-chief-info")
                edgeSwipe(app, commit: true)
                expectFocusedWithoutPage(app, "r\(round)-chief-info-back")
            } else {
                print("CMUX_FOCUS_TABBAR r\(round)-chief-info: SKIPPED (no Chief button)")
            }
            edgeSwipe(app, commit: true)
            if !app.tabBars.firstMatch.waitForExistence(timeout: 3) {
                let back = app.buttons["Back"].firstMatch
                if back.exists { back.tap() }
            }
            expectRoot(app, "r\(round)-home-root-after-workspace")
            // Back on Workspaces: its workspace (bar hidden) or its list (bar shown).
            select(app, "Workspaces")
            if app.descendants(matching: .any)["workspace.ws-cmux"].waitForExistence(timeout: 5) {
                expectFocused(app, "workspace.ws-cmux", "r\(round)-reselect-workspaces")
                leaveWorkspace(app)
            }
            expectRoot(app, "r\(round)-workspaces-root")
        }
    }

    /// A pushed chat or conversation (no page identifier): the bar goes and stays gone. The
    /// probe answering is the anchor that the app responded.
    @MainActor
    func expectFocusedWithoutPage(_ app: XCUIApplication, _ step: String) {
        expectBarGone(app, step, over: "the pushed screen", pageShown: Self.probe(app).waitForExistence(timeout: 15))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

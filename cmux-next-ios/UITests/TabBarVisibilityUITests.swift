import XCTest

/// The bottom tab bar stays fully visible while content scrolls: scrolling down never
/// minimizes it to the selected tab's pill. Real swipes on the tabs' root lists and on a
/// long pushed Settings page, against mock data. Home has no case: its mock content (one
/// Chief row) never scrolls, so the bar could not minimize there with or without the fix;
/// it shares the one `TabView` and its minimize behavior with the other tabs.
final class TabBarVisibilityUITests: XCTestCase {
    private static let tabs = ["Home", "Workspaces", "Feed", "Settings"]

    override func setUp() {
        continueAfterFailure = true
    }

    /// The largest text size, so the mock workspaces overflow the screen and the list scrolls.
    @MainActor func testWorkspacesKeepsTabBarWhileScrolling() {
        checkScrolling(tab: "workspaces",
                       extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"],
                       scrolls: "workspace.row.ws-cmux")
    }
    @MainActor func testFeedKeepsTabBarWhileScrolling() { checkScrolling(tab: "feed") }
    @MainActor func testSettingsKeepsTabBarWhileScrolling() { checkScrolling(tab: "settings") }

    @MainActor func testSettingsPageKeepsTabBarWhileScrolling() {
        checkScrolling(tab: "settings", extraArguments: ["-cmux-mobile-settings-page", "acknowledgements"])
    }

    /// Launches on `tab`, swipes the content up (scrolls down) and back, and checks that
    /// every tab button keeps its frame and stays hittable after each swipe. `scrolls` names
    /// a row that must move on the first swipe, proving the content really scrolled.
    @MainActor
    private func checkScrolling(tab: String, extraArguments: [String] = [], scrolls rowID: String? = nil) {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", tab, "-cmux-mobile-no-restore"] + extraArguments
        app.launch()
        // First run of mock data: pick the team.
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }

        let buttons = Self.tabs.map { app.tabBars.buttons[$0] }
        XCTAssertTrue(buttons[0].waitForExistence(timeout: 30), "tab bar\n\(app.debugDescription)")
        let name = extraArguments.first == "-cmux-mobile-settings-page" ? "\(tab)-\(extraArguments[1])" : tab
        let row = rowID.map { app.buttons[$0] }
        if let row { XCTAssertTrue(row.waitForExistence(timeout: 15), "\(name): row \(rowID ?? "")") }
        let rowTop = row?.frame.minY
        let before = buttons.map(\.frame)
        attach(app, "\(name)-before")

        for (step, direction) in ["up", "up", "up", "down", "up"].enumerated() {
            if direction == "up" { app.swipeUp(velocity: .fast) } else { app.swipeDown(velocity: .fast) }
            if step == 0, let row, let rowTop {
                XCTAssertTrue(!row.exists || row.frame.minY < rowTop - 50, "\(name): the content did not scroll")
            }
            let after = buttons.map(\.frame)
            for (index, button) in buttons.enumerated() {
                XCTAssertTrue(button.isHittable, "\(name): \(Self.tabs[index]) not hittable after swipe \(step + 1) (\(direction))")
                XCTAssertEqual(after[index], before[index],
                               "\(name): \(Self.tabs[index]) moved or shrank after swipe \(step + 1) (\(direction))")
            }
            print("CMUX_MOBILE_TABBAR \(name) swipe \(step + 1) \(direction): \(after.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" })")
            if step == 2 { attach(app, "\(name)-scrolled") }
        }
        attach(app, "\(name)-after")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

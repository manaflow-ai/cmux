import XCTest

/// The tab overview's pane filter, end to end with real taps (Leo, 2026-11-23: "a ... filtering
/// mechanism for only agent sessions, agent sessions/terminals, and ... browsers on their own
/// honestly should be a ... toggle"). Mock workspace `ws-cmux`: an agent, a terminal, a browser.
///
/// The default is agents and terminals, the browser tucked away and counted on the control; the
/// menu's Show Browsers brings it back, and Agents leaves the agent and the browser.
final class PaneFilterUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheFilterTucksBrowsersAwayAndBringsThemBack() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // The saved choice starts at the default (the argument domain wins over a past run's).
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                "-cmux.mobile.overview.paneFilter", "agents+terminals"]
        app.launch()

        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        row.tap()

        let tabsButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 15), "tabs button\n\(app.debugDescription)")
        tabsButton.tap()

        let cards = app.buttons.matching(NSPredicate(format: "label ENDSWITH ', tab'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 15), "grid cards\n\(app.debugDescription)")
        let filter = app.buttons["workspace.grid.paneFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "filter control\n\(app.debugDescription)")
        expectCards(cards, 2, "default: agent and terminal")
        let value = (filter.value as? String) ?? ""
        XCTAssertTrue(value.contains("1 browser hidden"), "hidden count: \(value)")
        // The header's tab count is never drawn under the filter: centered over the grid it ran
        // under the control and read "2 of 3 t".
        let count = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2 of 3 tabs'")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), "tab count\n\(app.debugDescription)")
        XCTAssertLessThanOrEqual(count.frame.maxX, filter.frame.minX, "tab count \(count.frame) clear of the filter \(filter.frame)")
        attach(app, "1-default")

        filter.tap()
        // A Toggle inside a menu is a menu button, not a switch.
        let browsers = app.buttons["Show Browsers"].firstMatch
        XCTAssertTrue(browsers.waitForExistence(timeout: 5), "Show Browsers\n\(app.debugDescription)")
        attach(app, "2-menu")
        browsers.tap()
        dismissMenu(app)
        expectCards(cards, 3, "browsers shown: every tab")
        let all = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH '3 tabs' AND NOT label CONTAINS ' of '")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5), "tab count\n\(app.debugDescription)")
        XCTAssertLessThanOrEqual(all.frame.maxX, filter.frame.minX, "tab count \(all.frame) clear of the filter \(filter.frame)")
        attach(app, "3-every-tab")

        filter.tap()
        let agents = app.buttons["Agents"].firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5), "Agents\n\(app.debugDescription)")
        agents.tap()
        dismissMenu(app)
        expectCards(cards, 2, "agents and browsers")
        attach(app, "4-agents-browsers")
    }

    @MainActor
    private func expectCards(_ cards: XCUIElementQuery, _ count: Int, _ what: String) {
        let shown = NSPredicate { _, _ in cards.allElementsBoundByIndex.filter { $0.frame.height > 50 }.count == count }
        wait(for: [expectation(for: shown, evaluatedWith: nil)], timeout: 10)
        print("CMUX_MOBILE_UI_CARDS \(what): \(cards.allElementsBoundByIndex.map(\.label))")
    }

    /// A menu stays open after a toggle; a tap outside it closes it.
    @MainActor
    private func dismissMenu(_ app: XCUIApplication) {
        guard app.buttons["Show Browsers"].exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.95)).tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

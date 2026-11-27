import XCTest

/// The tab overview's pane filter, end to end with real taps (Leo, 2026-11-23: "a ... filtering
/// mechanism for only agent sessions, agent sessions/terminals, and ... browsers on their own
/// honestly should be a ... toggle"). Mock workspace `ws-cmux`: an agent, a terminal, a browser.
///
/// The default is agents and terminals with browsers shown. More owns the filter rows, and the
/// menu's Show Browsers toggle can narrow and restore the grid.
final class PaneFilterUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheFilterShowsBrowsersByDefaultAndCanHideThem() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
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
        expectCards(cards, 3, "default: all panes")
        let title = app.staticTexts["workspace.grid.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "workspace title\n\(app.debugDescription)")
        XCTAssertEqual(title.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2,
                       "title midpoint \(title.frame) vs screen \(app.windows.firstMatch.frame)")
        attach(app, "1-default")

        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "More\n\(app.debugDescription)")
        more.tap()
        let browsers = app.buttons["Show Browsers"].firstMatch
        XCTAssertTrue(browsers.waitForExistence(timeout: 5), "Show Browsers\n\(app.debugDescription)")
        attach(app, "2-menu")
        browsers.tap()
        dismissMenu(app)
        expectCards(cards, 2, "browsers hidden")
        attach(app, "3-browsers-hidden")

        more.tap()
        let showBrowsers = app.buttons["Show Browsers"].firstMatch
        XCTAssertTrue(showBrowsers.waitForExistence(timeout: 5), "Show Browsers\n\(app.debugDescription)")
        showBrowsers.tap()
        dismissMenu(app)
        expectCards(cards, 3, "browsers shown again")
        attach(app, "4-every-tab")

        more.tap()
        let agents = app.buttons["Agents"].firstMatch
        XCTAssertTrue(agents.waitForExistence(timeout: 5), "Agents\n\(app.debugDescription)")
        agents.tap()
        dismissMenu(app)
        expectCards(cards, 2, "agents and browsers")
        attach(app, "5-agents-browsers")
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

import XCTest

/// The tab grid's split map (gallery variant, `CMUX_TABS_CARD_SPLIT_MAP=1`): on `ws-panes`
/// (build, server, logs | tests, git), each terminal's card shows its screen's two panes with
/// its own filled. A card is one accessibility element ("build, tab"), so the map is read as the
/// card's value ("Pane 1 of 2 in a split"). Without the variant the grid draws no map.
final class TabSplitMapUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testGridCardsShowTheirSplitMap() throws {
        let app = openGrid(variant: true)
        let maps = app.descendants(matching: .any).matching(NSPredicate(format: "value ENDSWITH ' in a split'"))
        XCTAssertTrue(maps.firstMatch.waitForExistence(timeout: 10), "split map on a card\n\(app.debugDescription)")
        attach(app, "grid-split-map")
        let values = Set(maps.allElementsBoundByIndex.compactMap { $0.value as? String })
        print("CMUX_TAB_SPLIT_MAP \(values.sorted())")
        XCTAssertTrue(values.isSubset(of: ["Pane 1 of 2 in a split", "Pane 2 of 2 in a split"]), "\(values)")
        // build is in the left pane, tests in the right one (MockData.mockPanesWorkspace).
        XCTAssertEqual(app.buttons["build, tab"].value as? String, "Pane 1 of 2 in a split")
        XCTAssertEqual(app.buttons["tests, tab"].value as? String, "Pane 2 of 2 in a split")
    }

    @MainActor
    func testGridWithoutTheVariantHasNoMap() throws {
        let app = openGrid(variant: false)
        attach(app, "grid-default")
        let maps = app.descendants(matching: .any).matching(NSPredicate(format: "value ENDSWITH ' in a split'"))
        XCTAssertTrue(app.buttons["build, tab"].waitForExistence(timeout: 10), "grid\n\(app.debugDescription)")
        XCTAssertFalse(maps.firstMatch.exists, "no split map by default")
    }

    /// The app on mock data, ws-panes open, its tab grid shown from the Tabs button.
    @MainActor
    private func openGrid(variant: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_MOCK_PANES"] = "1"
        if variant { app.launchEnvironment["CMUX_TABS_CARD_SPLIT_MAP"] = "1" }
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()

        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-panes"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        row.tap()

        let tabs = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'")).firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "tabs button\n\(app.debugDescription)")
        tabs.tap()
        Thread.sleep(forTimeInterval: 1.5)
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

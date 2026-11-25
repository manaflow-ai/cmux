import XCTest

/// Moving a terminal on the Panes page in one gesture: a long press lifts the tab's row and the
/// same touch drags it to its new place, in its own pane or another one. Before this, the page
/// had no drag: the long press opened the row's menu, and a move to another pane took Move Tab
/// to Pane, then the pane's name, and always landed at that pane's end.
///
/// Mock data: `CMUX_MOBILE_MOCK_PANES=1` lists `ws-panes`, build, server and logs in the left
/// pane and tests and git in the right one. Each test makes exactly one press-and-drag.
final class PaneDragMoveUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// logs, from the left pane, dropped on git's place in the right pane: it is now in the
    /// right pane, above git, and the left pane keeps build and server.
    @MainActor
    func testOneDragMovesATerminalIntoAnotherPane() throws {
        let app = openPanes()
        let logs = app.buttons["panes.tab.t-pane-logs"]
        let git = app.buttons["panes.tab.t-pane-git"]
        XCTAssertTrue(logs.waitForExistence(timeout: 15), "logs row\n\(app.debugDescription)")
        XCTAssertTrue(git.exists, "git row")
        print("CMUX_PANE_DRAG_BEFORE \(order(app))")
        attach(app, "before")

        drag(logs, onto: git, in: app)

        XCTAssertFalse(app.buttons["Move Tab to Pane"].exists, "the row's menu opened instead of a drag")
        let moved = expectation(for: NSPredicate { _, _ in self.pane(of: "t-pane-logs", in: app) == 2 }, evaluatedWith: nil)
        wait(for: [moved], timeout: 10)
        let after = order(app)
        print("CMUX_PANE_DRAG_AFTER \(after)")
        attach(app, "after")
        XCTAssertEqual(pane(of: "t-pane-build", in: app), 1)
        XCTAssertEqual(pane(of: "t-pane-server", in: app), 1)
        XCTAssertEqual(pane(of: "t-pane-tests", in: app), 2)
        XCTAssertEqual(after.firstIndex(of: "t-pane-logs").map { $0 + 1 }, after.firstIndex(of: "t-pane-git"),
                       "logs lands right above git: \(after)")
    }

    /// build, the left pane's first tab, dropped on logs' place: the pane's order changes in
    /// the same drag (the Panes page had no reorder at all).
    @MainActor
    func testOneDragReordersATerminalWithinItsPane() throws {
        let app = openPanes()
        let build = app.buttons["panes.tab.t-pane-build"]
        let logs = app.buttons["panes.tab.t-pane-logs"]
        XCTAssertTrue(build.waitForExistence(timeout: 15), "build row\n\(app.debugDescription)")
        let before = order(app)
        print("CMUX_PANE_REORDER_BEFORE \(before)")
        attach(app, "before")

        drag(build, onto: logs, in: app)

        XCTAssertFalse(app.buttons["Move Tab to Pane"].exists, "the row's menu opened instead of a drag")
        let moved = expectation(for: NSPredicate { _, _ in self.order(app).first != "t-pane-build" }, evaluatedWith: nil)
        wait(for: [moved], timeout: 10)
        let after = order(app)
        print("CMUX_PANE_REORDER_AFTER \(after)")
        attach(app, "after")
        XCTAssertEqual(pane(of: "t-pane-build", in: app), 1, "build stays in its pane")
        XCTAssertEqual(Set(after), Set(before))
    }

    // MARK: Helpers

    /// The app on mock data, ws-panes open, its Panes page pushed from the page menu.
    @MainActor
    private func openPanes() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_MOCK_PANES"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()

        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-panes"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        row.tap()

        // A terminal's bottom pill shows its title: a tap on it (or on the glyph) opens the page
        // menu; a collapsed pill takes its first tap to expand.
        let glyph = app.buttons["Page Menu"].firstMatch
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'build, '")).firstMatch
        let panes = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Panes'")).firstMatch
        XCTAssertTrue(glyph.waitForExistence(timeout: 15), "page menu\n\(app.debugDescription)")
        for _ in 0..<3 where !panes.exists {
            if pill.exists, pill.isHittable { pill.tap() } else if glyph.isHittable { glyph.tap() }
            _ = panes.waitForExistence(timeout: 4)
        }
        XCTAssertTrue(panes.exists, "Panes in the page menu\n\(app.debugDescription)")
        attach(app, "page-menu")
        panes.tap()
        XCTAssertTrue(app.descendants(matching: .any)["panes.screen"].waitForExistence(timeout: 10), "Panes page\n\(app.debugDescription)")
        return app
    }

    /// The one gesture: hold past the long press, then move to the top of `target` and hold there
    /// while the rows make room, then lift.
    @MainActor
    private func drag(_ row: XCUIElement, onto target: XCUIElement, in app: XCUIApplication) {
        let from = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        from.press(forDuration: 0.8, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.8)
    }

    /// The tab rows' ids, top to bottom.
    @MainActor
    private func order(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'panes.tab.'")).allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 20 }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { String($0.identifier.dropFirst("panes.tab.".count)) }
    }

    /// Which pane's section the tab's row is in: the last pane header above it (1 or 2).
    @MainActor
    private func pane(of tab: String, in app: XCUIApplication) -> Int? {
        let row = app.buttons["panes.tab.\(tab)"]
        guard row.exists else { return nil }
        let headers = [1, 2].compactMap { id -> (Int, CGFloat)? in
            let header = app.buttons["panes.menu.\(id)"]
            return header.exists ? (id, header.frame.minY) : nil
        }
        return headers.filter { $0.1 < row.frame.minY }.max { $0.1 < $1.1 }?.0
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

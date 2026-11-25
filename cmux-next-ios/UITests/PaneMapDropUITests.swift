import XCTest

/// Prototype (unmerged): the Panes page's layout map takes a drop. A tab row dragged onto a
/// pane's box moves the tab to that pane's end, so a move to another pane doesn't need its
/// section on screen. Mock data `CMUX_MOBILE_MOCK_PANES=1`: build, server and logs in pane 1,
/// tests and git in pane 2.
final class PaneMapDropUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testDropOnTheMapMovesATabToThatPane() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_MOCK_PANES"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-panes"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()
        let glyph = app.buttons["Page Menu"].firstMatch
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'build, '")).firstMatch
        let panes = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Panes'")).firstMatch
        XCTAssertTrue(glyph.waitForExistence(timeout: 15))
        for _ in 0..<3 where !panes.exists {
            if pill.exists, pill.isHittable { pill.tap() } else if glyph.isHittable { glyph.tap() }
            _ = panes.waitForExistence(timeout: 4)
        }
        panes.tap()

        let server = app.buttons["panes.tab.t-pane-server"]
        let box = app.descendants(matching: .any)["panes.diagram.2"]
        XCTAssertTrue(server.waitForExistence(timeout: 15), "server row\n\(app.debugDescription)")
        XCTAssertTrue(box.waitForExistence(timeout: 5), "pane 2's box\n\(app.debugDescription)")
        sleep(1)
        let from = server.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.8, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.8)

        let header2 = app.buttons["panes.menu.2"]
        let moved = expectation(for: NSPredicate { _, _ in
            server.exists && header2.exists && server.frame.minY > header2.frame.minY
        }, evaluatedWith: nil)
        wait(for: [moved], timeout: 10)
        sleep(2)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "after"; shot.lifetime = .keepAlways; add(shot)
    }
}

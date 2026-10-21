import XCTest

/// Drag to reorder in a workspace's tab grid with real touches (verify/parity-mac.md, Tabs):
/// a long press lifts the card, moving the finger then drags it to another slot. A simulated
/// HID drag (axe) opened the card menu instead, so this runs as an XCUITest.
///
/// Mock data by default (workspace `ws-cmux`). With `TEST_RUNNER_CMUX_MOBILE_UI_WORKSPACE=<id>` it drives
/// the paired Mac's workspace instead (`TEST_RUNNER_CMUX_MOBILE_UI_SLOTS`: how many leading cards take
/// part, all in one pane), and the caller checks the Mac's order (pq_tabs.py).
final class TabReorderUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDragMovesACardToAnotherSlot() throws {
        let env = ProcessInfo.processInfo.environment
        let live = env["CMUX_MOBILE_UI_WORKSPACE"]
        let app = XCUIApplication()
        if live == nil { app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1" }
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()

        // First run of mock data: pick the team whose Mac holds the workspace.
        let choose = app.scrollViews["setup.teams.choose"]
        if live == nil, choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.\(live ?? "ws-cmux")"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        row.tap()

        // The grid: TabsKit's Tabs button in the bottom toolbar.
        let tabsButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs' OR label BEGINSWITH[c] 'Show All Tabs' OR label BEGINSWITH[c] 'Tab overview'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 15), "tabs button\n\(app.debugDescription)")
        tabsButton.tap()

        // Grid cards are buttons labelled "<title>, tab", in grid order.
        let cards = app.buttons.matching(NSPredicate(format: "label ENDSWITH ', tab'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 15), "grid cards\n\(app.debugDescription)")
        let count = min(cards.count, Int(env["CMUX_MOBILE_UI_SLOTS"] ?? "3") ?? 3)
        XCTAssertGreaterThanOrEqual(count, 2, "two cards to reorder")
        let before = order(cards)
        attach(app, "before")
        print("CMUX_MOBILE_UI_BEFORE \(before)")

        // Hold past the 0.5 s long press, then drag the first card onto the slot of card `count - 1`.
        let first = cards.element(matching: NSPredicate(format: "label == %@", before[0]))
        let target = cards.element(matching: NSPredicate(format: "label == %@", before[count - 1]))
        let from = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        from.press(forDuration: 0.8, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.6)

        // No card menu: the press became a drag.
        XCTAssertFalse(app.buttons["Rename Tab…"].exists, "the card menu opened instead of a drag")
        let expected = Array(before[1..<count]) + [before[0]] + Array(before.dropFirst(count))
        let moved = expectation(for: NSPredicate { _, _ in Array(self.order(cards).prefix(before.count)) == expected }, evaluatedWith: nil)
        wait(for: [moved], timeout: 10)
        print("CMUX_MOBILE_UI_AFTER \(order(cards))")
        attach(app, "after")
    }

    /// The cards' labels, top to bottom and left to right.
    @MainActor
    private func order(_ cards: XCUIElementQuery) -> [String] {
        cards.allElementsBoundByIndex.filter { $0.frame.height > 50 }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            .map(\.label)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

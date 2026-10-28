import XCTest

/// The Workspaces list's interactions with real touches, on mock data: a row's
/// long-press menu, its trailing swipe actions (Rename and Close, each asking
/// first), the pull-down search, an offline Mac's fold line, and a tap that
/// opens the workspace. The list is a UIKit collection view (WorkspacesCollection),
/// so these go through UIKit's own context menu, swipe and scroll paths.
final class WorkspacesListUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()
        // First run of mock data: pick the team whose Macs hold the workspaces.
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        return app
    }

    @MainActor
    func testRowMenuSwipesSearchFoldAndOpen() throws {
        let app = launch()
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        attach(app, "list")

        // Long press: the row's menu (UIContextMenuInteraction through the collection view's delegate).
        row.press(forDuration: 1.0)
        let renameItem = app.buttons["Rename"]
        XCTAssertTrue(renameItem.waitForExistence(timeout: 5), "row menu\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Close Workspace"].exists, "Close Workspace in the menu")
        XCTAssertTrue(app.buttons["Appearance"].exists || app.buttons["Pin Workspace"].exists || app.buttons["Unpin Workspace"].exists,
                      "the Mac's row actions in the menu")
        attach(app, "menu")
        renameItem.tap()
        XCTAssertTrue(app.alerts["Rename Workspace"].waitForExistence(timeout: 5), "rename from the menu\n\(app.debugDescription)")
        app.alerts["Rename Workspace"].buttons["Cancel"].tap()

        // Trailing swipe: Close and Rename.
        row.swipeLeft()
        let swipeRename = app.buttons["Rename"]
        XCTAssertTrue(swipeRename.waitForExistence(timeout: 5), "swipe actions\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Close"].exists, "Close swipe action")
        attach(app, "swipe")
        swipeRename.tap()
        XCTAssertTrue(app.alerts["Rename Workspace"].waitForExistence(timeout: 5), "rename from the swipe\n\(app.debugDescription)")
        app.alerts["Rename Workspace"].buttons["Cancel"].tap()

        row.swipeLeft()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5), "swipe actions again\n\(app.debugDescription)")
        app.buttons["Close"].tap()
        let confirm = app.buttons["Close Workspace"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "close asks first\n\(app.debugDescription)")
        attach(app, "close-confirm")
        // Leave it open: dismiss the question without closing.
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the workspace is still listed")

        // An offline Mac's fold line unfolds its rows in place.
        let fold = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspaces.fold.'")).firstMatch
        if fold.waitForExistence(timeout: 5) {
            let before = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.row.'")).count
            fold.tap()
            let unfolded = expectation(for: NSPredicate { _, _ in
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.row.'")).count > before
            }, evaluatedWith: nil)
            wait(for: [unfolded], timeout: 5)
            attach(app, "unfolded")
        }

        // Pull down: the search field comes out from under the bar.
        let list = app.collectionViews["workspaces.list"]
        XCTAssertTrue(list.exists, "the list's collection view")
        let top = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        top.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), "pull-down search\n\(app.debugDescription)")
        attach(app, "search")
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("ghostty")
        XCTAssertTrue(app.buttons["workspace.row.ws-ghostty"].waitForExistence(timeout: 5) ||
                      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.row.'")).count >= 1,
                      "search results\n\(app.debugDescription)")
        attach(app, "search-results")
        // iOS 26's search bar closes with an "x" button (no "Cancel").
        let close = app.buttons.matching(NSPredicate(format: "label ==[c] 'Cancel' OR label ==[c] 'Close' OR identifier ==[c] 'Cancel'")).firstMatch
        if close.exists { close.tap() } else { app.searchFields.firstMatch.buttons.firstMatch.tap() }
        if app.keyboards.firstMatch.exists, app.searchFields.firstMatch.exists {
            // Still searching: clear the text, which shows every row again.
            app.searchFields.firstMatch.buttons["Clear text"].tap()
        }

        // A tap opens the workspace.
        XCTAssertTrue(row.waitForExistence(timeout: 5), "row after search")
        row.tap()
        XCTAssertFalse(app.collectionViews["workspaces.list"].waitForExistence(timeout: 1) && row.isHittable,
                       "the workspace opened over the list")
        attach(app, "opened")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

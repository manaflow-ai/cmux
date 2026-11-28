import XCTest

/// Aziz, TestFlight, 2026-11-25: a Workspaces row ("Browser Dogfood") stayed drawn as selected,
/// and its fill never cleared after going back. A list in a navigation stack shows the
/// selection while the row is tapped and clears it after the pop (Apple HIG, Lists and tables;
/// UIKit's `clearsSelectionOnViewWillAppear`). Push a workspace, pop back, and no row is
/// selected once the fade is over, by either way back (the Back button, the edge swipe).
final class WorkspaceRowSelectionClearsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-tab", "workspaces"]
        app.launch()
        return app
    }

    private func rows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.row."))
    }

    /// The edge swipe back, else the page's Back button.
    @MainActor
    private func goBack(_ app: XCUIApplication, swipe: Bool) {
        if swipe {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            if app.tabBars.firstMatch.waitForExistence(timeout: 3) { return }
        }
        let back = app.buttons["Back"].firstMatch
        if back.waitForExistence(timeout: 5), back.isEnabled { back.tap() }
    }

    @MainActor
    func testNoRowStaysSelectedAfterPushAndPop() {
        let app = launch()
        defer { app.terminate() }
        for (round, (workspace, swipe)) in [("ws-cmux", false), ("ws-web", true), ("ws-cmux", true)].enumerated() {
            let row = app.buttons["workspace.row.\(workspace)"]
            XCTAssertTrue(row.waitForExistence(timeout: 30), "row \(workspace)\n\(app.debugDescription)")
            row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["workspace.\(workspace)"].waitForExistence(timeout: 15),
                          "r\(round): the workspace opened\n\(app.debugDescription)")
            goBack(app, swipe: swipe)
            XCTAssertTrue(row.waitForExistence(timeout: 15), "r\(round): back on the list\n\(app.debugDescription)")
            // The return highlight itself, inside its 0.3 s hold: the frame a reviewer looks at for the flash.
            attach(app, "r\(round)-return-flash-\(workspace)")
            // Past the return highlight's hold and fade (ReturnHighlight: 0.3 s + 0.35 s).
            Thread.sleep(forTimeInterval: 1.5)
            let selected = rows(app).allElementsBoundByIndex.filter { $0.exists && $0.isSelected }.map(\.identifier)
            attach(app, "r\(round)-back-from-\(workspace)")
            XCTAssertEqual(selected, [], "r\(round): rows still selected after the pop: \(selected)")
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

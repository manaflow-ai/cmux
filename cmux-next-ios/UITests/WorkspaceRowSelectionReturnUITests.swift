import XCTest

/// Aziz, 2026-11-25: the rounded highlight on a tapped Workspaces row stayed on after going back from
/// that workspace. The row's selected fill and its "selected" accessibility trait share one flag
/// (`WorkspaceRowModel.isSelected`), so the trait is what this checks: on while nothing is open is the bug.
///
/// For each look (light, dark): tap a row, go back with Back, then tap it again and go back with an
/// edge swipe, then open a second row and go back. After every return no row is selected. Every step
/// attaches the screen (`cmux-next-ios-sim.sh test ui=WorkspaceRowSelectionReturnUITests video`).
final class WorkspaceRowSelectionReturnUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testTappedRowIsNotSelectedAfterReturning() {
        for look in ["light", "dark"] {
            XCUIDevice.shared.orientation = .portrait
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                    "-cmuxMobile.settings.appearance", look]
            app.launch()
            let choose = app.scrollViews["setup.teams.choose"]
            if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
            let cmux = app.buttons["workspace.row.ws-cmux"]
            XCTAssertTrue(cmux.waitForExistence(timeout: 30), "\(look): workspace list\n\(app.debugDescription)")
            attach(app, "\(look)-1-list")

            // Back button.
            open(app, "ws-cmux", look: look, step: "2-open")
            // The top bar's own Back (identifier chevron.left), not a UINavigationBar button.
            let back = app.buttons["Back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5), "\(look): no Back button")
            back.tap()
            expectNoSelection(app, look: look, step: "3-after-back")

            // Interactive swipe back from the left edge.
            open(app, "ws-cmux", look: look, step: "4-reopen")
            swipeBack(app)
            expectNoSelection(app, look: look, step: "5-after-swipe-back")

            // Another row: only it was ever selected, and it clears too.
            open(app, "ws-web", look: look, step: "6-open-other")
            swipeBack(app)
            expectNoSelection(app, look: look, step: "7-after-other")
            app.terminate()
        }
    }

    @MainActor
    private func open(_ app: XCUIApplication, _ id: String, look: String, step: String) {
        let row = app.buttons["workspace.row.\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(look) \(step): row \(id)")
        row.tap()
        let page = app.descendants(matching: .any)["workspace.\(id)"]
        XCTAssertTrue(page.waitForExistence(timeout: 15), "\(look) \(step): workspace \(id) not shown")
        attach(app, "\(look)-\(step)")
    }

    @MainActor
    private func swipeBack(_ app: XCUIApplication) {
        // The keyboard would take the drag; close it first.
        if app.keyboards.firstMatch.exists { app.swipeDown(velocity: .fast) }
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)),
                    withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// Back on the list, after the return's fade: no row carries the selected trait.
    @MainActor
    private func expectNoSelection(_ app: XCUIApplication, look: String, step: String) {
        let cmux = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(cmux.waitForExistence(timeout: 15), "\(look) \(step): not back on the list")
        // Past the 0.35 s fade.
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "\(look)-\(step)")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.row.'"))
        let selected = rows.allElementsBoundByIndex.filter(\.isSelected).map(\.identifier)
        print("CMUX_ROW_SELECTION \(look) \(step): selected=\(selected)")
        XCTAssertEqual(selected, [], "\(look) \(step): a row stayed selected after returning to the list")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

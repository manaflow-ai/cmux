import XCTest

/// The tab grid's top controls (Workspaces back, More) are the same glass circles as its
/// bottom bar (+ and Done): one toolbar size, top and bottom. They were 36 pt over a 48 pt
/// bottom bar (person, 2026-11-05: "the top toolbar buttons ... are too small, they should
/// match the sizes at the bottom"). Mock data, workspace `ws-cmux`.
final class GridToolbarSizeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTopControlsMatchTheBottomBar() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"]
        app.launch()

        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        let row = app.buttons["workspace.row.ws-cmux"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace row\n\(app.debugDescription)")
        row.tap()

        let tabsButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs'")).firstMatch
        XCTAssertTrue(tabsButton.waitForExistence(timeout: 15), "tabs button\n\(app.debugDescription)")
        let pageBar = tabsButton.frame
        tabsButton.tap()

        // Several elements share these labels (the root tab bar's Workspaces, a parked page's
        // More): take the one on screen in the grid's top row or bottom bar.
        let screen = app.windows.firstMatch.frame
        func control(_ label: String, top: Bool) -> XCUIElement? {
            app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex.first { e in
                let f = e.frame
                guard e.exists, f.width > 0, f.minX >= 0, f.maxX <= screen.maxX + 1 else { return false }
                return top ? f.maxY < screen.height * 0.2 : f.minY > screen.height * 0.8
            }
        }
        var back: XCUIElement?, more: XCUIElement?, done: XCUIElement?
        // The grid's zoom settles: wait for the top row to rest on one line, then measure.
        let settled = expectation(for: NSPredicate { _, _ in
            back = control("Workspaces", top: true)
            more = control("More", top: true)
            done = control("Done", top: false)
            guard let b = back, let m = more, done != nil else { return false }
            return abs(b.frame.midY - m.frame.midY) < 1
        }, evaluatedWith: nil)
        wait(for: [settled], timeout: 15)
        guard let back, let more, let done else { return XCTFail("grid controls\n\(app.debugDescription)") }
        attach(app, "grid")

        let bottom = done.frame
        print("CMUX_MOBILE_UI_SIZES page-tabs=\(pageBar.size) back=\(back.frame.size) more=\(more.frame.size) done=\(bottom.size)")
        // Height is the toolbar size (the bottom bar's Done reports its row's width, not its
        // circle's, so widths are not compared across bars).
        for (name, top) in [("Workspaces", back.frame), ("More", more.frame)] {
            XCTAssertEqual(top.height, bottom.height, accuracy: 1, "\(name) is \(top.size), the bottom bar's Done is \(bottom.size)")
            XCTAssertGreaterThanOrEqual(top.height, 44, "\(name) is under the 44 pt minimum hit target")
        }
        // Back is a circle, as wide as it is tall.
        XCTAssertEqual(back.frame.width, back.frame.height, accuracy: 1, "Workspaces is \(back.frame.size)")
        // Back and More share one row.
        XCTAssertEqual(back.frame.midY, more.frame.midY, accuracy: 1)

        // The same grid in the other appearance, for the before and after pictures.
        let appearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = appearance == .dark ? .light : .dark
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        attach(app, appearance == .dark ? "grid-light" : "grid-dark")
        XCUIDevice.shared.appearance = appearance
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

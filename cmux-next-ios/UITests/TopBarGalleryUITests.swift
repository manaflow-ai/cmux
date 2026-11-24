import XCTest

/// Gallery of the top bar's placement (Leo 2026-11-23: "we keep the "safari" esque thing. but we
/// move it to the top"): the shipped `grid` (2 pt under the status bar, 20 pt sides, Back where
/// the tab grid's back circle is) and three variants, each on an agent chat with the keyboard
/// down and up, and on the tab grid. Screens only; it asserts no taste.
final class TopBarGalleryUITests: XCTestCase {
    @MainActor
    func testTopBarVariants() {
        for variant in ["grid", "edge", "airy", "safari"] {
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                    "-cmux-mobile-topbar-variant", variant]
            app.launch()
            let choose = app.scrollViews["setup.teams.choose"]
            if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
            let row = app.buttons["workspace.row.ws-cmux"]
            XCTAssertTrue(row.waitForExistence(timeout: 30), "\(variant): row")
            row.tap()
            _ = app.descendants(matching: .any)["workspace.ws-cmux"].waitForExistence(timeout: 15)
            shot(app, "\(variant)-chat")
            let field = app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch
            if field.waitForExistence(timeout: 10), field.isHittable {
                field.tap()
                if app.keyboards.firstMatch.waitForExistence(timeout: 8) { shot(app, "\(variant)-keyboard") }
                app.swipeDown(velocity: .fast)
            }
            let tabs = app.buttons.matching(NSPredicate(format: "label ==[c] 'Tabs'")).firstMatch
            if tabs.waitForExistence(timeout: 10) {
                tabs.tap()
                _ = app.buttons["Done"].waitForExistence(timeout: 10)
                shot(app, "\(variant)-grid")
            }
            let back = app.buttons["Back"].firstMatch
            print("CMUX_TOPBAR_GALLERY \(variant) back=\(back.exists ? "\(back.frame)" : "none")")
            app.terminate()
        }
    }

    @MainActor
    func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "topbar-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }
}

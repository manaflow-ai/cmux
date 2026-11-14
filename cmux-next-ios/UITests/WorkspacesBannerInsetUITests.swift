import XCTest

/// The connection banner takes its own room over the Workspaces list: the
/// list's first line starts under it (and a tap on that line hits the line,
/// not the banner), and when the banner goes the list moves back up under the
/// bar. The list is a UIKit collection view behind `ignoresSafeArea`, so the
/// banner's SwiftUI `safeAreaInset` alone never reached it. Drives the DEBUG
/// `-cmux-mobile-banner-demo pairing` state on mock data; run with `video`.
final class WorkspacesBannerInsetUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(banner: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-tab", "workspaces"]
        if let banner { app.launchArguments += ["-cmux-mobile-banner-demo", banner] }
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5) { app.buttons["Manaflow"].tap() }
        XCTAssertTrue(app.buttons["workspace.row.ws-cmux"].waitForExistence(timeout: 30), "mock rows\n\(app.debugDescription)")
        return app
    }

    /// The list's topmost line (a title, a Mac line or a row: every item is a cell).
    @MainActor
    private func firstLine(_ app: XCUIApplication) -> XCUIElement {
        let list = app.collectionViews["workspaces.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "the list's collection view\n\(app.debugDescription)")
        let cell = list.cells.element(boundBy: 0)
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "the list's first line\n\(app.debugDescription)")
        return cell
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testTheListStartsBelowTheBannerAndMovesBackWhenItGoes() {
        // Without a banner: where the first line sits under the bar.
        let plain = launch(banner: nil)
        let restingTop = firstLine(plain).frame.minY
        attach(plain, "no-banner")
        plain.terminate()

        let app = launch(banner: "pairing")
        defer { app.terminate() }
        let banner = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Approve this iPhone on")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "the pairing banner\n\(app.debugDescription)")
        let line = firstLine(app)
        attach(app, "banner")
        XCTAssertGreaterThanOrEqual(line.frame.minY, banner.frame.maxY - 0.5,
                                    "the first line \(line.frame) starts under the banner \(banner.frame)")
        XCTAssertTrue(line.isHittable, "a tap on the first line hits it, not the banner")

        // A tap hides the banner: the list moves back up to where it rests without one.
        banner.tap()
        let top = app.collectionViews["workspaces.list"].cells.element(boundBy: 0)
        let back = expectation(for: NSPredicate { _, _ in
            top.exists && abs(top.frame.minY - restingTop) <= 1
        }, evaluatedWith: nil)
        wait(for: [back], timeout: 5)
        attach(app, "banner-dismissed")
    }
}

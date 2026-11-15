import XCTest

/// Tapping a workspace of an offline Mac explains why it can't open: an alert
/// "{mac} is offline", "… opens when the Mac is awake with cmux running.".
final class OfflineWorkspaceAlertUITests: XCTestCase {
    @MainActor
    func testTappingAnOfflineMacsWorkspaceShowsTheAlert() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-tab", "workspaces"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons.matching(identifier: "workspace.row.ws-cmux").firstMatch.waitForExistence(timeout: 30), "The list loaded.")
        let fold = app.descendants(matching: .any).matching(identifier: "workspaces.fold.mbp").firstMatch
        XCTAssertTrue(fold.waitForExistence(timeout: 10), "The offline Mac's fold line is listed.")
        // The collapsed list is too short to scroll, and its last line sits at the floating
        // tab bar's edge, where XCUITest calls it not hittable: tap its center directly.
        fold.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let row = app.buttons.matching(identifier: "workspace.row.ws-zed").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The fold opens the offline Mac's rows.")
        // Bring the opened row clear of the tab bar (lower 20% of the screen).
        let floor = app.frame.height * 0.8
        for _ in 0..<6 where row.frame.maxY > floor { app.swipeUp() }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "An offline Mac's workspace shows the offline alert.")
        XCTAssertTrue(alert.label.hasSuffix("is offline"), "Alert title: \(alert.label)")
        let body = alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "opens when the Mac is awake")).firstMatch
        XCTAssertTrue(body.exists, "The alert says when it will open.")
        _ = app.buttons["never.there"].waitForExistence(timeout: 2)
        alert.buttons["OK"].tap()
    }
}

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

        XCTAssertTrue(app.buttons["workspace.row.ws-cmux"].waitForExistence(timeout: 30), "The list loaded.")
        let fold = app.descendants(matching: .any)["workspaces.fold.mbp"]
        for _ in 0..<4 where !(fold.exists && fold.isHittable) { app.swipeUp() }
        XCTAssertTrue(fold.waitForExistence(timeout: 10), "The offline Mac's fold line is listed.")
        fold.tap()
        let row = app.buttons["workspace.row.ws-zed"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The fold opens the offline Mac's rows.")
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "An offline Mac's workspace shows the offline alert.")
        XCTAssertTrue(alert.label.hasSuffix("is offline"), "Alert title: \(alert.label)")
        let body = alert.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "opens when the Mac is awake")).firstMatch
        XCTAssertTrue(body.exists, "The alert says when it will open.")
        _ = app.buttons["never.there"].waitForExistence(timeout: 2)
        alert.buttons["OK"].tap()
    }
}

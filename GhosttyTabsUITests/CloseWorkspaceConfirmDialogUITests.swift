import XCTest

final class CloseWorkspaceConfirmDialogUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCmdShiftWShowsCloseWorkspaceConfirmationText() {
        let app = XCUIApplication()
        // Force the workspace-close path to require confirmation so we can assert the alert copy.
        app.launchEnvironment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] = "1"
        app.launch()
        app.activate()

        app.typeKey("w", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            waitForCloseWorkspaceAlert(app: app, timeout: 5.0),
            "Expected Cmd+Shift+W to show the close workspace confirmation alert"
        )

        // Dismiss without changing state.
        clickCancelOnCloseWorkspaceAlert(app: app)

        XCTAssertFalse(
            isCloseWorkspaceAlertPresent(app: app),
            "Expected close workspace confirmation alert to dismiss after clicking Cancel"
        )
    }

    private func isCloseWorkspaceAlertPresent(app: XCUIApplication) -> Bool {
        if closeWorkspaceDialog(app: app).exists { return true }
        if closeWorkspaceAlert(app: app).exists { return true }
        return app.staticTexts["Close workspace?"].exists
    }

    private func waitForCloseWorkspaceAlert(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isCloseWorkspaceAlertPresent(app: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return isCloseWorkspaceAlertPresent(app: app)
    }

    private func clickCancelOnCloseWorkspaceAlert(app: XCUIApplication) {
        let dialog = closeWorkspaceDialog(app: app)
        if dialog.exists {
            dialog.buttons["Cancel"].firstMatch.click()
            return
        }
        let alert = closeWorkspaceAlert(app: app)
        if alert.exists {
            alert.buttons["Cancel"].firstMatch.click()
            return
        }
        // Best-effort fallback: target the front-most dialog-like element to avoid Touch Bar collisions.
        let anyDialog = app.dialogs.firstMatch
        if anyDialog.exists, anyDialog.buttons["Cancel"].exists {
            anyDialog.buttons["Cancel"].firstMatch.click()
            return
        }
    }

    private func closeWorkspaceDialog(app: XCUIApplication) -> XCUIElement {
        app.dialogs.containing(.staticText, identifier: "Close workspace?").firstMatch
    }

    private func closeWorkspaceAlert(app: XCUIApplication) -> XCUIElement {
        app.alerts.containing(.staticText, identifier: "Close workspace?").firstMatch
    }
}

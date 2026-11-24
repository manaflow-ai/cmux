import XCTest

/// Settings → Needs You look = Glow (the Mac's `notifications.attention.mark`, off by default): the
/// Workspaces list's Needs You and Done rows breathe a halo in place of their dot until opened. A
/// capture for the PR's clip (`cmux-next-ios-sim.sh test ui=NeedsYouGlowCaptureUITests video`): the
/// list holds still long enough to see a few 2.4 s breaths, then an opened row stops glowing.
final class NeedsYouGlowCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testGlowingRowsBreatheUntilOpened() {
        for look in ["dark", "light"] {
            XCUIDevice.shared.orientation = .portrait
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore",
                                    "-cmuxMobile.settings.appearance", look,
                                    "-cmuxMobile.settings.attentionMark", "glow"]
            app.launch()
            let choose = app.scrollViews["setup.teams.choose"]
            if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
            let row = app.buttons["workspace.row.ws-cmux"]
            XCTAssertTrue(row.waitForExistence(timeout: 30), "workspace list\n\(app.debugDescription)")
            // A few breaths of the halo on the waiting rows.
            Thread.sleep(forTimeInterval: 7)
            attach(app, "glow-\(look)")
            // Opening a waiting row marks it seen: back on the list it shows its dot, not the glow.
            row.tap()
            Thread.sleep(forTimeInterval: 2)
            let back = app.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 5) { back.tap() }
            Thread.sleep(forTimeInterval: 4)
            attach(app, "opened-\(look)")
            app.terminate()
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

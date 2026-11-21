import XCTest

/// The drawer's Create team, tapped for real (mock account): Teams, then `+`, then
/// Create team, a typed name, Create, and the new team is in the drawer's list. The
/// mock account answers the create itself; the production request is covered by
/// CmuxMobileModelTests/TeamCreationRouteTests and verify/create-team.md.
final class CreateTeamUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateTeamFromTheDrawer() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }

        let teams = app.buttons["Teams"].firstMatch
        XCTAssertTrue(teams.waitForExistence(timeout: 30), "Teams button\n\(app.debugDescription)")
        teams.tap()
        let add = app.buttons["Add team"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "drawer + button\n\(app.debugDescription)")
        attach(app, "01-drawer")
        add.tap()
        let create = app.buttons["Create team"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10), "Create team menu item\n\(app.debugDescription)")
        attach(app, "02-menu")
        create.tap()

        let alert = app.alerts["Create team"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Create team alert\n\(app.debugDescription)")
        let field = alert.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "team name field")
        field.tap()
        field.typeText("ios create team")
        attach(app, "03-named")
        alert.buttons["Create"].tap()

        XCTAssertTrue(alert.waitForNonExistence(timeout: 10), "the alert stayed up")
        // The new team shows in the drawer's list (reopen the drawer if the switch closed it).
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ios create team")).firstMatch
        if !row.waitForExistence(timeout: 5), teams.exists { teams.tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the new team never listed\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["Couldn't create the team"].exists)
        XCTAssertFalse(app.staticTexts["Your account can't create teams"].exists)
        attach(app, "04-created")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

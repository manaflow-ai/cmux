import XCTest

/// The team drawer's header (mock data, no account): "Teams" as its title, no
/// "cmux" wordmark, and Invite beside the `+` for the selected team. Invite
/// names the team it acts on, a tap on it starts that team's invite, the old
/// "Invite to team" row under the list is gone, and the personal space has no
/// Invite. Every state is attached in light and dark, and at an accessibility
/// text size, where Invite is its glyph alone.
final class TeamDrawerInviteUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testInviteSitsInTheHeaderForTheSelectedTeam() {
        for look in ["light", "dark"] {
            run(look: look, largeText: false)
        }
    }

    @MainActor
    func testInviteAtAnAccessibilityTextSize() {
        run(look: "light", largeText: true)
    }

    @MainActor
    private func run(look: String, largeText: Bool) {
        let suffix = look + (largeText ? "-ax" : "")
        XCUIDevice.shared.appearance = look == "dark" ? .dark : .light
        let app = XCUIApplication()
        // The mock account, signed in and past setup, as the UI-state captures launch it.
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES"]
        app.launchArguments += ["-cmuxMobile.settings.appearance", look,
                                "-cmux-mobile-tab", "workspaces", "-cmux-mobile-sidebar-open"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        }
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 5), app.buttons["Manaflow"].exists { app.buttons["Manaflow"].tap() }

        // The header: "Teams", no wordmark. (Open the drawer if the launch didn't.)
        let title = app.staticTexts["Teams"].firstMatch
        let add = app.buttons["Add team"].firstMatch
        if !add.waitForExistence(timeout: 15) || !add.isHittable {
            let teams = app.buttons["Teams"].firstMatch
            XCTAssertTrue(teams.waitForExistence(timeout: 30), "Teams button\n\(app.debugDescription)")
            teams.tap()
        }
        XCTAssertTrue(add.waitForExistence(timeout: 10), "drawer + button\n\(app.debugDescription)")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "drawer title\n\(app.debugDescription)")
        let wordmark = app.staticTexts.matching(identifier: "cmux").allElementsBoundByIndex
            .filter { abs($0.frame.midY - title.frame.midY) < 12 }
        XCTAssertTrue(wordmark.isEmpty, "the cmux wordmark is still in the drawer header")

        // Invite, for the selected team (Manaflow in the mock data), next to `+`.
        let invite = app.buttons["sidebar.invite"]
        XCTAssertTrue(invite.waitForExistence(timeout: 10), "header Invite\n\(app.debugDescription)")
        XCTAssertEqual(invite.label, "Invite to Manaflow")
        XCTAssertTrue(invite.isHittable)
        XCTAssertEqual(invite.frame.midY, add.frame.midY, accuracy: 2, "Invite and + share the header row")
        XCTAssertLessThan(invite.frame.maxX, add.frame.minX, "Invite sits before +")
        XCTAssertLessThan(title.frame.maxX, invite.frame.minX, "the title is not under Invite")
        // The row under the list is gone.
        XCTAssertFalse(app.buttons["Invite to team"].exists, "the old Invite to team row is still listed")
        attach(app, "01-header-manaflow-\(suffix)")

        // A tap starts the selected team's invite. With no cmux service (mock
        // data) it ends in the "needs the cmux service" toast; live, it opens
        // the email alert or the share sheet.
        invite.tap()
        let toast = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Invite links need the cmux service")).firstMatch
        let emailAlert = app.alerts["Invite to Manaflow"]
        let started = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in toast.exists || emailAlert.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 15), .completed,
                       "the invite never started\n\(app.debugDescription)")
        attach(app, "02-invite-tapped-\(suffix)")
        if emailAlert.exists { emailAlert.buttons["Cancel"].tap() }
        if largeText { return }

        // Another team: Invite follows the selection.
        switchTeam(app, to: "Build Fleet")
        XCTAssertTrue(invite.waitForExistence(timeout: 10), "header Invite after the switch\n\(app.debugDescription)")
        XCTAssertEqual(invite.label, "Invite to Build Fleet")
        attach(app, "03-header-build-fleet-\(suffix)")

        // The personal space: nobody to invite, so no Invite.
        switchTeam(app, to: "Personal")
        XCTAssertTrue(app.staticTexts["Teams"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(invite.waitForNonExistence(timeout: 5), "Invite shows for the personal space")
        XCTAssertTrue(app.buttons["Add team"].firstMatch.exists)
        attach(app, "04-header-personal-\(suffix)")
    }

    /// Taps the team's row; the switch closes the drawer (ShellModel.switchTeam),
    /// so wait for it to leave the accessibility tree, then open it again.
    @MainActor
    private func switchTeam(_ app: XCUIApplication, to name: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(name) row\n\(app.debugDescription)")
        row.tap()
        let add = app.buttons["Add team"].firstMatch
        XCTAssertTrue(add.waitForNonExistence(timeout: 5), "the drawer stayed open after the switch")
        let teams = app.buttons["Teams"].firstMatch
        XCTAssertTrue(teams.waitForExistence(timeout: 10), "Teams button\n\(app.debugDescription)")
        teams.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 10), "drawer reopened\n\(app.debugDescription)")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

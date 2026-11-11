import XCTest

/// The user, 2026-11-09: typing `/` in the Chief composer should suggest what can be called, as the
/// agent chats do. Opens the mock Chief, types `/`, and checks the list shows its skills; typing more
/// filters it; tapping a row puts `/name ` in the field; a path such as `/tmp` shows no list. Before,
/// `/` in the iPhone's Chief chat showed nothing.
final class ChiefSlashSkillsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSlashListsFiltersAndPicksAChiefSkill() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "chief-open"]
        app.launch()

        let field = app.textViews["conversation.composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Chief's composer\n\(app.debugDescription)")
        field.tap()
        attach(app, "0-composer")

        field.typeText("/")
        XCTAssertTrue(app.buttons["chief.slash.row./cmux-views"].waitForExistence(timeout: 5),
                      "/ lists a Chief skill\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["chief.slash.row./emil-prototype"].exists, "a Claude skill is listed")
        attach(app, "1-slash-all")

        field.typeText("tri")
        let triage = app.buttons["chief.slash.row./triage"]
        XCTAssertTrue(triage.waitForExistence(timeout: 5), "/tri keeps triage")
        XCTAssertFalse(app.buttons["chief.slash.row./cmux-views"].exists, "/tri drops cmux-views")
        attach(app, "2-slash-filtered")

        triage.tap()
        XCTAssertEqual(field.value as? String, "/triage ", "the pick fills the command and a space")
        XCTAssertFalse(app.buttons["chief.slash.row./triage"].exists, "the list closes after a pick")
        attach(app, "3-picked")

        // Clear and type a path: a command no skill names is a plain message, no list.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        field.typeText("/tmp/build.log")
        XCTAssertFalse(app.buttons["chief.slash.row./triage"].exists, "a path shows no list")
        attach(app, "4-path")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

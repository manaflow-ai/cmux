import XCTest

/// CMUX-19: a Markdown table from Chief shows as a table (cells under their
/// headers), not as pipe syntax. Real touches on the mock Chief (mock sign-in):
/// asked for "agents table", it answers with a three-column Markdown table.
final class ChiefMarkdownTableUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testChiefTableShowsAsColumns() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "chief-open"]
        app.launch()

        let field = app.textViews["conversation.composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Chief's composer\n\(app.debugDescription)")
        field.tap()
        field.typeText("Show my agents table")
        app.buttons["conversation.composer.send"].tap()

        let reply = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "a42")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "Chief's table reply\n\(app.debugDescription)")
        let label = reply.label
        XCTAssertFalse(label.contains("|"), "no pipe syntax in the bubble: \(label)")
        XCTAssertFalse(label.contains("---"), "no delimiter row in the bubble: \(label)")
        for cell in ["Agent", "Task", "State", "a42", "Keyboard", "building", "a49", "Panes", "done", "a52", "Pin tab", "open"] {
            XCTAssertTrue(label.contains(cell), "cell \"\(cell)\" kept: \(label)")
        }
        // Dismiss the keyboard so the whole table is in the shot.
        app.swipeDown()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "chief-table"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

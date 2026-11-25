import XCTest

/// Aziz 2026-11-03: "the … more button on rows has an empty menu group top level." The answer's
/// action row (a native row) built its … menu from a deferred element that returned the whole menu,
/// which UIKit shows as a submenu: the menu opened on one empty, untitled row with a chevron, and
/// Copy as Markdown and Retry were one more tap away. Opened once, the menu shows its items.
final class AgentRowMenuUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRowMoreMenuShowsItsItemsAtTheTopLevel() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "disclosure-chat"]
        app.launch()
        defer { app.terminate() }

        let header = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 30), "the pushed agent chat opens\n\(app.debugDescription)")
        // The newest answer's … button, in the transcript (below the navigation bar).
        let rowMore = app.buttons.matching(NSPredicate(format: "label == %@", "More")).allElementsBoundByIndex
            .filter { $0.frame.minY > header.frame.maxY + 20 }
            .max { $0.frame.minY < $1.frame.minY }
        guard let rowMore else { return XCTFail("an answer's … button is on screen\n\(app.debugDescription)") }
        rowMore.tap()

        let copy = app.buttons["Copy as Markdown"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Copy as Markdown shows with one tap\n\(app.debugDescription)")
        XCTAssertTrue(copy.isHittable, "Copy as Markdown is on the menu's top level")
        XCTAssertTrue(app.buttons["Retry"].firstMatch.exists, "Retry is on the menu's top level")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "row-more-menu"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

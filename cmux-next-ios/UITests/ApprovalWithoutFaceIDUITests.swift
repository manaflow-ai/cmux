import XCTest

/// The user's call (2026-11-04): an Allow asks for no Face ID. The Feed's
/// permission card offers "Allow once" as plain text, with no Face ID glyph
/// in front of it (before, the label read "  Allow once": the glyph's text
/// attachment), and nothing on the Feed mentions Face ID. That the Allow then
/// signs with no prompt is PhoneKeys' unit test (`theApprovalKeySignsWithoutAPrompt`).
final class ApprovalWithoutFaceIDUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFeedAllowCarriesNoFaceID() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }

        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 30), "the Feed's table\n\(app.debugDescription)")
        let permission = list.cells["feed.row.f-permission"]
        XCTAssertTrue(permission.waitForExistence(timeout: 10), "a permission row\n\(app.debugDescription)")
        reveal(permission, in: list)

        let allow = permission.buttons.matching(NSPredicate(format: "label CONTAINS 'Allow'")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "the card's Allow\n\(app.debugDescription)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "feed-permission"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertEqual(allow.label, "Allow once", "the Allow has no Face ID glyph")
        let faceID = NSPredicate(format: "label CONTAINS[c] 'Face ID'")
        XCTAssertEqual(app.descendants(matching: .any).matching(faceID).count, 0, "nothing mentions Face ID")
    }

    @MainActor private func reveal(_ cell: XCUIElement, in list: XCUIElement) {
        for _ in 0..<12 {
            let top = list.frame.minY + 100, limit = list.frame.minY + list.frame.height * 0.6
            if cell.exists, cell.frame.minY >= top, cell.frame.minY <= limit { return }
            if cell.exists, cell.frame.minY < top { list.swipeDown(velocity: .slow) } else { list.swipeUp(velocity: .slow) }
        }
    }
}

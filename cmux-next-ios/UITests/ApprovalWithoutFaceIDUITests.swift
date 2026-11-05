import XCTest

/// The user's call (2026-11-04): an Allow asks for no Face ID. On mock data
/// with a slow mock approval, the Feed's permission card says "Sending…" while
/// the Allow goes out, then its buttons go; nothing on screen mentions Face ID.
/// Before, the card said "Waiting for Face ID…" and its Allow carried a Face ID glyph.
final class ApprovalWithoutFaceIDUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAllowInTheFeedSendsWithoutFaceID() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // Both names of the slow mock switch, so the same test runs on a build before the rename.
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore",
                                "-cmuxMobile.dev.slowApproval", "YES", "-cmuxMobile.dev.slowFaceID", "YES"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }

        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 30), "the Feed's table\n\(app.debugDescription)")
        let permission = list.cells["feed.row.f-permission"]
        XCTAssertTrue(permission.waitForExistence(timeout: 10), "a permission row\n\(app.debugDescription)")
        reveal(permission, in: list)
        attach(app, "1-permission")

        let allow = permission.buttons.matching(NSPredicate(format: "label CONTAINS 'Allow'")).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "the card's Allow\n\(app.debugDescription)")
        allow.tap()

        // The card's pending line (FeedRowCell's `feed.permission.pending`) while the Allow goes out.
        let pending = app.descendants(matching: .any)["feed.permission.pending"]
        XCTAssertTrue(pending.waitForExistence(timeout: 3), "the pending line\n\(app.debugDescription)")
        attach(app, "2-sending")
        XCTAssertFalse(pending.label.contains("Face ID"), "the pending line says \(pending.label)")
        XCTAssertTrue(pending.label.contains("Sending"), "the pending line says \(pending.label)")

        // Then the Allow is decided: the card's buttons go away.
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: allow)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "the Allow went out\n\(app.debugDescription)")
        attach(app, "3-allowed")
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

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

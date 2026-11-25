import XCTest

/// The open asks at the top of the Feed's All view sit under a "Needs you · N" label, and an
/// answered ask leaves the group for its place in time. Real touches on mock data: two asks are
/// open (a question, 1 minute old, and a permission, 7 minutes old) above a reply 4 minutes old.
/// Allowing the permission drops the label to 1 and puts the permission below that reply.
/// Before, the group had no label and the answered row jumped with a section rebuild.
final class FeedNeedsYouLabelUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAnAnsweredAskLeavesTheLabelledGroup() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }

        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 30), "the Feed's table\n\(app.debugDescription)")
        let label = list.descendants(matching: .any).matching(identifier: "feed.needsYouLabel").firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 10), "the pinned group's label\n\(app.debugDescription)")
        XCTAssertEqual(label.label, "Needs you · 2", "two asks are open")
        attach(app, "label-two")

        // The permission is pinned: the question is above it, the newer reply below it.
        let question = list.cells["feed.row.f-question"]
        let permission = list.cells["feed.row.f-permission"]
        let reply = list.cells["feed.row.f-pricing"]
        XCTAssertTrue(permission.waitForExistence(timeout: 10), "a permission row\n\(app.debugDescription)")
        reveal(permission, in: list)
        XCTAssertTrue(question.exists, "the question is the row above the pinned permission\n\(app.debugDescription)")
        XCTAssertLessThan(question.frame.minY, permission.frame.minY, "the question is above the permission")
        if reply.exists {
            XCTAssertGreaterThan(reply.frame.minY, permission.frame.minY, "the newer reply is below the pinned permission")
        }
        attach(app, "pinned")

        let allow = permission.buttons["Allow once"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "the card's Allow\n\(app.debugDescription)")
        allow.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: allow)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 15), .completed, "the permission is answered")
        attach(app, "answered")

        // Back at the top, the label counts the one ask left.
        for _ in 0..<12 where !(label.exists && label.isHittable) { list.swipeDown(velocity: .slow) }
        XCTAssertTrue(label.exists, "the label stays while an ask is open\n\(app.debugDescription)")
        XCTAssertEqual(label.label, "Needs you · 1", "one ask is left")
        attach(app, "label-one")

        // The answered permission is in time order now: under the reply that is newer than it.
        reveal(permission, in: list)
        XCTAssertTrue(permission.exists, "the answered permission stays in the Feed\n\(app.debugDescription)")
        XCTAssertTrue(reply.exists, "the newer reply is the row above the answered permission\n\(app.debugDescription)")
        XCTAssertLessThan(reply.frame.minY, permission.frame.minY, "the answered permission is below the newer reply")
        attach(app, "in-time-order")
    }

    /// Scrolls the list with slow swipes until `cell` starts in its upper part.
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

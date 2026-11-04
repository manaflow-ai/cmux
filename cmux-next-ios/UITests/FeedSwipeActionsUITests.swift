import XCTest

/// Feed rows use UIKit's own swipe actions, driven by real touches on mock data:
/// the list is a table whose rows answer a left swipe with the system's trailing
/// actions (Done and Read on a reply, Deny and Allow on a permission), Read flips
/// to Unread on the next swipe, and a full swipe performs the outermost action
/// (Done removes the row), and a row that grows (Show more) gets its new height
/// from the table. Before, the Feed was a collection view whose cells
/// slid themselves with their own pan recognizer and drew their own buttons.
final class FeedSwipeActionsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFeedRowsUseNativeSwipeActions() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }

        // The Feed is a UITableView: UIKit owns its rows' swipe actions.
        let list = app.tables["feed.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 30), "the Feed's table\n\(app.debugDescription)")
        // A permission row: Deny (outermost, the full swipe) and Allow.
        let permission = list.cells["feed.row.f-permission"]
        XCTAssertTrue(permission.waitForExistence(timeout: 10), "a permission row\n\(app.debugDescription)")
        reveal(permission, in: list)
        attach(app, "list")
        permission.swipeLeft()
        // "Allow" is the swipe action's own label (the card's button says "Allow once"); the card's own
        // Deny button is there too, so a second Deny is the swipe action.
        let allow = list.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "native swipe actions\n\(app.debugDescription)")
        XCTAssertEqual(list.buttons.matching(identifier: "Deny").count, 2, "Deny swipe action beside the card's Deny")
        attach(app, "swipe-permission")
        // A tap on the row puts it back (UIKit), performing nothing.
        permission.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(waitGone(allow), "the actions close on a tap")
        XCTAssertTrue(permission.exists, "the permission row stays after a tap")

        // A reply row: Done (outermost) and Read; Read flips to Unread on the next swipe.
        let row = list.cells["feed.row.f-pricing"]
        reveal(row, in: list)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "a reply row\n\(app.debugDescription)")
        row.swipeLeft()
        let read = list.buttons["Read"]
        XCTAssertTrue(read.waitForExistence(timeout: 5), "Read swipe action\n\(app.debugDescription)")
        XCTAssertTrue(list.buttons["Done"].exists, "Done swipe action")
        attach(app, "swipe-open")
        read.tap()
        XCTAssertTrue(waitGone(read), "the actions close after Read")
        row.swipeLeft()
        let unread = list.buttons["Unread"]
        XCTAssertTrue(unread.waitForExistence(timeout: 5), "Unread after Read\n\(app.debugDescription)")
        attach(app, "swipe-unread")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(waitGone(unread), "the actions close on a tap")

        // A full swipe performs the outermost action: Done removes the row.
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: -0.4, dy: 0.3)))
        XCTAssertTrue(waitGone(row), "a full swipe marks the row done\n\(app.debugDescription)")
        attach(app, "full-swipe-done")

        // A row that grows (Show more) gets its new height from the table.
        let long = list.cells["feed.row.f-long"]
        reveal(long, in: list)
        let more = long.buttons["Show more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "Show more on the long row\n\(app.debugDescription)")
        let collapsed = long.frame.height
        more.tap()
        let grown = expectation(for: NSPredicate { _, _ in long.frame.height > collapsed + 20 }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [grown], timeout: 5), .completed,
                       "the expanded row is taller than \(collapsed) pt, got \(long.frame.height)")
        XCTAssertTrue(long.buttons["Show less"].exists, "Show less after expanding")
        attach(app, "expanded")
    }

    /// Scrolls the list with slow swipes until `cell` starts in its upper part.
    @MainActor private func reveal(_ cell: XCUIElement, in list: XCUIElement) {
        for _ in 0..<12 {
            let top = list.frame.minY + 100, limit = list.frame.minY + list.frame.height * 0.6
            if cell.exists, cell.frame.minY >= top, cell.frame.minY <= limit { return }
            if cell.exists, cell.frame.minY < top { list.swipeDown(velocity: .slow) } else { list.swipeUp(velocity: .slow) }
        }
    }

    @MainActor private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

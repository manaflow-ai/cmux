import UIKit
import XCTest

/// Recordings, not checks: the two Feed gestures from the 2026-11-18 iPhone report, done slowly and
/// repeated so the simulator step's UI video shows every frame of them
/// (`scripts/ci/cmux-next-ios-sim.sh test ui=FeedScrollSwipeCaptureUITests video`).
///
/// - A code block in a Feed row scrolled sideways: the code coming in at the trailing edge should
///   draw as it arrives, not after the finger stops.
/// - An open row's swipe actions dragged back to the right: the row should close in place, with the
///   row above untouched.
final class FeedScrollSwipeCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launchFinishedFeed() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // A fixed Feed with no live traffic: only the gestures move anything.
        app.launchEnvironment["CMUX_MOBILE_FEED_STRESS"] = "60"
        app.launchArguments += ["-cmux-mobile-tab", "feed", "-cmux-mobile-no-restore", "-cmuxMobile.settings.appearance", "dark"]
        app.launch()
        _ = feedChipsAfterSetup(app)
        app.buttons["Finished"].firstMatch.tap()
        XCTAssertTrue(app.tables["feed.list"].waitForExistence(timeout: 10))
        pause(1.5)
        return app
    }

    // MARK: Code block scroll

    @MainActor
    func testCodeBlockScrollRecording() throws {
        let app = launchFinishedFeed()
        // The stress Feed's diff block ("- grid-template-columns: repeat(3, 1fr);"), wider than its card.
        let code = app.tables["feed.list"].staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'grid-template-columns'")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10), "the diff code block\n\(app.debugDescription)")
        let width = app.windows.firstMatch.frame.width
        let rest = code.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // Inside the card on both ends: a drag that starts left of the card would open the drawer.
        let leading = origin.withOffset(CGVector(dx: rest.minX + 12, dy: rest.midY))
        let trailing = origin.withOffset(CGVector(dx: width - 40, dy: rest.midY))
        attach("code-rest")
        for pass in 1...3 {
            trailing.press(forDuration: 0.3, thenDragTo: leading, withVelocity: .slow, thenHoldForDuration: 1.2)
            attach("code-scrolled-\(pass)")
            pause(1)
            leading.press(forDuration: 0.3, thenDragTo: trailing, withVelocity: .slow, thenHoldForDuration: 1.2)
            pause(1)
        }
    }

    // MARK: Swipe back

    @MainActor
    func testSwipeBackRecording() throws {
        let app = launchFinishedFeed()
        let list = app.tables["feed.list"]
        let barBottom = app.navigationBars["Feed"].frame.maxY
        let tabBarTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : list.frame.maxY
        // A row with at least 120 pt of the row above it on screen, and all of itself.
        func pick() -> String? {
            guard let snap = try? list.snapshot() else { return nil }
            return snap.children.lazy
                .filter { $0.identifier.hasPrefix("feed.row.") }
                .first { $0.frame.minY > barBottom + 140 && $0.frame.minY + 120 < tabBarTop - 20 }?
                .identifier
        }
        var found = pick()
        for _ in 0..<6 where found == nil {
            list.swipeUp(velocity: .slow)
            found = pick()
        }
        let id = try XCTUnwrap(found, "a row with the row above it on screen\n\(app.debugDescription)")
        let row = list.cells[id]
        pause(1)
        attach("swipe-rest")
        for (pass, velocity) in [(1, XCUIGestureVelocity.default), (2, .slow), (3, .default)] {
            row.swipeLeft()
            XCTAssertTrue(list.buttons["Done"].waitForExistence(timeout: 5), "the row's swipe actions (pass \(pass))")
            pause(1.2)
            attach("swipe-open-\(pass)")
            // Back to the right, a finger's drag from the row's leading part (the report's gesture).
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)),
                       withVelocity: velocity, thenHoldForDuration: 0)
            pause(1.5)
            attach("swipe-closed-\(pass)")
        }
    }

    // MARK: Helpers

    @MainActor private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: seconds)
    }

    @MainActor private func attach(_ name: String) {
        let shot = XCTAttachment(image: XCUIScreen.main.screenshot().image)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

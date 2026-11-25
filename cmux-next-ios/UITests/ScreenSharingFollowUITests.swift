import XCTest

/// Follow mode in the Screen Sharing viewer, on the built-in demo desktop
/// (`-CmuxMobileScreenSharingDemo -CmuxMobileScreenSharingFollowDemo`): a
/// scripted "Mac" types a long command line into the desktop's terminal
/// window and sends the caret after each character. Portrait. The crop
/// starts fitted (Follow off), the Follow button turns it on, and it follows the typing to the end
/// of the line; a drag takes the view and a tap hands it back. Screenshots
/// at each step; run with `video` for the recording.
final class ScreenSharingFollowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testFollowModeFollowsALongTypedLineInPortrait() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CmuxMobileScreenSharingDemo", "-CmuxMobileScreenSharingFollowDemo", "-cmux-mobile-no-restore"]
        app.launch()

        let screen = app.scrollViews["screen.view"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "viewer\n\(app.debugDescription)")
        let follow = app.buttons["screen.follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 30), "Follow button once the desktop says its display\n\(app.debugDescription)")
        XCTAssertEqual(follow.value as? String, "Off")
        attach(app, "01-portrait-fitted-follow-off")

        // Follow stays off until the person turns it on; the script types once it is on.
        settle(2)
        XCTAssertEqual(follow.value as? String, "Off", "Follow turned itself on")
        follow.tap()
        XCTAssertTrue(wait(for: follow, value: "On", timeout: 10), "the button did not turn Follow on\n\(app.debugDescription)")
        settle(1)
        attach(app, "02-follow-on-readable-crop")
        for step in 3 ... 8 {
            settle(1.5)
            attach(app, String(format: "%02d-typing-the-line", step))
        }

        // A drag takes the view: the button says it can resume.
        screen.swipeRight()
        XCTAssertTrue(wait(for: follow, value: "Held", timeout: 5), "a drag did not take the view\n\(app.debugDescription)")
        settle(1)
        attach(app, "09-held-by-a-drag")
        // A tap hands it back (and clicks nothing).
        screen.tap()
        XCTAssertTrue(wait(for: follow, value: "On", timeout: 5), "a tap did not hand the view back\n\(app.debugDescription)")
        settle(1.5)
        attach(app, "10-back-on-the-caret")
    }

    private func wait(for element: XCUIElement, value: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

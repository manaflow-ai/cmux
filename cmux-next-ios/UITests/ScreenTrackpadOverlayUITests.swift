import XCTest

/// CMUX-14: the Screen Sharing viewer's trackpad is a drawer under the screen.
/// Closed by default, only its handle shows at the bottom edge; swiping the
/// handle up slides it in under the screen (the screen moves up above it),
/// and swiping down hides it. The viewer settings live inside it instead of
/// on the screen. Runs on the built-in demo desktop
/// (`-CmuxMobileScreenSharingDemo`), so no Mac is needed.
final class ScreenTrackpadOverlayUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTrackpadDrawerSwipesUpUnderTheScreenAndSwipesDownToHide() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CmuxMobileScreenSharingDemo", "-cmux-mobile-no-restore"]
        app.launch()

        let screen = app.scrollViews["screen.view"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "viewer\n\(app.debugDescription)")
        let handle = app.descendants(matching: .any)["screen.trackpad.handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 30), "trackpad handle once connected\n\(app.debugDescription)")
        let drawer = app.otherElements["screen.trackpad.drawer"]
        let pad = app.descendants(matching: .any)["screen.trackpad.pad"]
        let window = app.windows.firstMatch.frame
        settle(app, 1)
        attach(app, "01-closed-by-default")

        // Closed by default: only the handle, at the bottom edge; no settings on the screen.
        XCTAssertEqual(drawer.value as? String, "closed")
        XCTAssertFalse(pad.exists, "trackpad surface shown while closed")
        XCTAssertFalse(app.buttons["screen.options"].exists, "viewer settings on the screen")
        XCTAssertGreaterThan(handle.frame.minY, window.maxY - 140, "handle not at the bottom edge (\(handle.frame))")
        XCTAssertTrue(handle.isHittable, "handle not reachable")
        let fullScreenBottom = screen.frame.maxY

        // Swipe up: the drawer slides in under the screen, which moves up above it.
        handle.swipeUp()
        XCTAssertTrue(wait(for: drawer, value: "open"), "drawer did not open on swipe up\n\(app.debugDescription)")
        XCTAssertTrue(pad.waitForExistence(timeout: 5), "trackpad surface\n\(app.debugDescription)")
        XCTAssertTrue(pad.isHittable, "trackpad surface not reachable")
        XCTAssertGreaterThanOrEqual(pad.frame.minY, window.midY - 40, "drawer is not at the bottom (\(pad.frame))")
        XCTAssertLessThanOrEqual(screen.frame.maxY, handle.frame.minY + 1,
                                 "screen not above the drawer (screen \(screen.frame), handle \(handle.frame))")
        XCTAssertLessThan(screen.frame.maxY, fullScreenBottom - 150, "screen did not move up")
        settle(app, 1)
        attach(app, "02-swiped-up")

        // The viewer settings are inside the drawer.
        let settings = app.buttons["screen.options"]
        XCTAssertTrue(settings.exists, "viewer settings in the drawer\n\(app.debugDescription)")
        settings.tap()
        XCTAssertTrue(app.buttons["Refresh Screen"].firstMatch.waitForExistence(timeout: 5), "settings menu\n\(app.debugDescription)")
        attach(app, "03-settings")
        app.buttons["Refresh Screen"].firstMatch.tap()

        // A stroke on the pad moves the pointer and leaves the drawer open.
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)))
        XCTAssertEqual(drawer.value as? String, "open", "a stroke on the pad closed the drawer")

        // Swipe down: hidden again, the screen back to full height.
        handle.swipeDown()
        XCTAssertTrue(wait(for: drawer, value: "closed"), "drawer did not hide on swipe down\n\(app.debugDescription)")
        XCTAssertFalse(pad.exists, "trackpad surface still shown after swipe down")
        XCTAssertGreaterThanOrEqual(screen.frame.maxY, fullScreenBottom - 1, "screen did not return to full height")
        settle(app, 1)
        attach(app, "04-swiped-down")
    }

    @MainActor
    func wait(for element: XCUIElement, value: String, timeout: TimeInterval = 5) -> Bool {
        let done = expectation(for: NSPredicate(format: "value == %@", value), evaluatedWith: element)
        return XCTWaiter().wait(for: [done], timeout: timeout) == .completed
    }

    /// Lets the drawer's spring and the next frames finish before a screenshot (a bounded wait on the test clock).
    @MainActor
    func settle(_ app: XCUIApplication, _ seconds: TimeInterval) {
        _ = app.staticTexts["never-appears"].waitForExistence(timeout: seconds)
    }

    @MainActor
    func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

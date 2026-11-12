import XCTest

/// CMUX-14: the Screen Sharing viewer's trackpad. It is closed by default
/// behind an obvious Trackpad button; the button opens a draggable overlay
/// with a trackpad surface, and the viewer settings live inside the overlay
/// instead of on the screen. Runs on the built-in demo desktop
/// (`-CmuxMobileScreenSharingDemo`), so no Mac is needed.
final class ScreenTrackpadOverlayUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTrackpadIsClosedByDefaultAndOpensADraggableOverlayWithTheSettings() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CmuxMobileScreenSharingDemo", "-cmux-mobile-no-restore"]
        app.launch()

        let screen = app.scrollViews["screen.view"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "viewer\n\(app.debugDescription)")
        let show = app.buttons["screen.trackpad.show"]
        XCTAssertTrue(show.waitForExistence(timeout: 30), "Trackpad button once connected\n\(app.debugDescription)")
        attach(app, "01-closed-by-default")

        // Closed by default, and the screen itself shows no viewer settings.
        let overlay = app.otherElements["screen.trackpad.overlay"]
        XCTAssertFalse(overlay.exists, "overlay open before the button was tapped")
        XCTAssertFalse(app.buttons["screen.options"].exists, "viewer settings still on the screen")
        XCTAssertTrue(show.isHittable, "Trackpad button not tappable")

        // The button opens the overlay: a trackpad surface and the viewer settings inside it.
        show.tap()
        XCTAssertTrue(overlay.waitForExistence(timeout: 5), "overlay\n\(app.debugDescription)")
        let pad = overlay.descendants(matching: .any)["screen.trackpad.pad"]
        XCTAssertTrue(pad.exists, "trackpad surface\n\(app.debugDescription)")
        let settings = overlay.buttons["screen.options"]
        XCTAssertTrue(settings.exists, "viewer settings inside the overlay\n\(app.debugDescription)")
        XCTAssertFalse(show.exists, "Trackpad button shown while the overlay is open")
        attach(app, "02-open")

        // The settings menu opens from the overlay.
        settings.tap()
        XCTAssertTrue(app.buttons["Refresh Screen"].firstMatch.waitForExistence(timeout: 5), "settings menu\n\(app.debugDescription)")
        attach(app, "03-settings")
        app.buttons["Refresh Screen"].firstMatch.tap()

        // One finger on the pad moves the pointer; the overlay stays put.
        let before = overlay.frame
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)))
        XCTAssertEqual(overlay.frame, before, "a stroke on the pad moved the overlay")

        // Dragging the grip moves the overlay up.
        let grip = overlay.descendants(matching: .any)["screen.trackpad.grip"]
        grip.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: grip.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: -6)))
        let moved = overlay.frame
        XCTAssertLessThan(moved.minY, before.minY - 60, "overlay did not move with its grip (\(before) -> \(moved))")
        XCTAssertGreaterThanOrEqual(moved.minY, app.windows.firstMatch.frame.minY, "overlay dragged off screen")
        attach(app, "04-dragged")

        // Hide closes it and brings the Trackpad button back.
        overlay.buttons["screen.trackpad.hide"].tap()
        XCTAssertTrue(show.waitForExistence(timeout: 5), "Trackpad button after hiding")
        XCTAssertFalse(overlay.exists, "overlay still open after Hide")
        attach(app, "05-hidden")
    }

    @MainActor
    func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

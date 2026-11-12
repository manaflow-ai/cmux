import GameController
import XCTest

/// The Screen Sharing viewer's always-visible trackpad. The toolbar, the
/// screen (fitted to the width) and the trackpad stack top to bottom, the
/// trackpad up by default and filling the rest. Dragging its notch down
/// tucks it away to a strip at the bottom edge and the screen takes the
/// room; dragging it up (or tapping the notch) brings it back. The viewer
/// settings stay on the top bar. Runs on the built-in demo desktop
/// (`-CmuxMobileScreenSharingDemo`), so no Mac is needed.
final class ScreenTrackpadOverlayUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testTrackpadIsUpUnderTheScreenAndItsNotchTucksItAwayAndBack() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CmuxMobileScreenSharingDemo", "-cmux-mobile-no-restore"]
        app.launch()

        let screen = app.scrollViews["screen.view"]
        XCTAssertTrue(screen.waitForExistence(timeout: 30), "viewer\n\(app.debugDescription)")
        let handle = app.descendants(matching: .any)["screen.trackpad.handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 30), "trackpad notch once connected\n\(app.debugDescription)")
        let drawer = app.otherElements["screen.trackpad.drawer"]
        let pad = app.descendants(matching: .any)["screen.trackpad.pad"]
        let options = app.buttons["screen.options"]
        // The notch's touch target reaches 7 points above the drawer's top edge (a 44-point target over a 30-point strip).
        func drawerTop() -> CGFloat { handle.frame.minY + 7 }
        let window = app.windows.firstMatch.frame
        settle(app, 1.5)
        attach(app, "01-portrait-trackpad-up-by-default")

        // Up by default: the pad fills the lower part, the screen sits above it, the toolbar above that.
        XCTAssertEqual(drawer.value as? String, "open")
        XCTAssertTrue(pad.waitForExistence(timeout: 5), "trackpad surface shown by default\n\(app.debugDescription)")
        XCTAssertTrue(pad.isHittable, "trackpad surface not reachable")
        XCTAssertGreaterThan(pad.frame.height, window.height * 0.3, "trackpad too small (\(pad.frame))")
        XCTAssertGreaterThan(pad.frame.minY, window.midY - 120, "trackpad not in the lower part (\(pad.frame))")
        XCTAssertLessThanOrEqual(screen.frame.maxY, drawerTop() + 1,
                                 "screen not above the trackpad (screen \(screen.frame), notch \(handle.frame))")
        XCTAssertTrue(options.exists, "viewer settings on the top bar\n\(app.debugDescription)")
        XCTAssertLessThanOrEqual(options.frame.maxY, screen.frame.minY + 1, "toolbar covers the screen (\(options.frame), \(screen.frame))")
        let upScreenHeight = screen.frame.height

        // A stroke on the pad moves the pointer and leaves the trackpad up.
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.6))
            .press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.35)))
        settle(app, 0.6)
        attach(app, "02-stroke-moved-the-pointer")
        pad.tap()
        settle(app, 0.6)
        XCTAssertEqual(drawer.value as? String, "open", "the pad's stroke or tap moved the drawer")

        // Drag the notch down: tucked away to a strip, the screen takes the room.
        handle.swipeDown()
        XCTAssertTrue(wait(for: drawer, value: "closed"), "notch drag down did not tuck the trackpad away\n\(app.debugDescription)")
        XCTAssertTrue(pad.waitForNonExistence(timeout: 5), "trackpad surface still shown while tucked away")
        XCTAssertGreaterThan(handle.frame.minY, window.maxY - 90, "notch strip not at the bottom edge (\(handle.frame))")
        XCTAssertTrue(handle.isHittable, "notch not reachable while tucked away")
        settle(app, 1)
        XCTAssertGreaterThan(screen.frame.height, upScreenHeight + 150, "screen did not take the room")
        XCTAssertLessThanOrEqual(screen.frame.maxY, drawerTop() + 1, "the notch strip covers the screen")
        attach(app, "03-portrait-tucked-away")

        // Drag it up: back.
        handle.swipeUp()
        XCTAssertTrue(wait(for: drawer, value: "open"), "notch drag up did not bring the trackpad back\n\(app.debugDescription)")
        XCTAssertTrue(pad.waitForExistence(timeout: 5), "trackpad surface after drag up")
        settle(app, 1)
        XCTAssertEqual(screen.frame.height, upScreenHeight, accuracy: 2, "screen height after bringing it back")
        attach(app, "04-portrait-brought-back")

        // A tap on the notch toggles.
        handle.tap()
        XCTAssertTrue(wait(for: drawer, value: "closed"), "notch tap did not tuck it away")
        handle.tap()
        XCTAssertTrue(wait(for: drawer, value: "open"), "notch tap did not bring it back")

        // The software keyboard covers the trackpad: the screen keeps the room above it.
        app.buttons["Keyboard"].firstMatch.tap()
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            settle(app, 1)
            XCTAssertGreaterThan(screen.frame.height, 150, "keyboard squeezed the screen (\(screen.frame))")
            XCTAssertLessThanOrEqual(screen.frame.maxY, app.keyboards.firstMatch.frame.minY + 60, "screen under the keyboard")
            attach(app, "05-portrait-keyboard-up")
            app.buttons["Keyboard"].firstMatch.tap()
            settle(app, 1)
        }
        XCTAssertEqual(screen.frame.height, upScreenHeight, accuracy: 2, "screen height after the keyboard")

        // Landscape: tucked away at first (height is short), brought up and tucked away again.
        XCUIDevice.shared.orientation = .landscapeLeft
        settle(app, 2.5)
        XCTAssertEqual(drawer.value as? String, "closed", "landscape starts tucked away")
        attach(app, "06-landscape-tucked-away")
        handle.swipeUp()
        XCTAssertTrue(wait(for: drawer, value: "open"), "notch drag up in landscape")
        XCTAssertTrue(pad.waitForExistence(timeout: 5), "trackpad in landscape")
        settle(app, 1)
        attach(app, "07-landscape-trackpad-up")
        handle.swipeDown()
        XCTAssertTrue(wait(for: drawer, value: "closed"), "notch drag down in landscape")

        // Back in portrait: the remembered portrait choice (up) again.
        XCUIDevice.shared.orientation = .portrait
        settle(app, 2)
        XCTAssertEqual(drawer.value as? String, "open", "portrait keeps its own choice")
        XCTAssertTrue(pad.waitForExistence(timeout: 5), "trackpad back in portrait")

        // Last, the options menu (on a headless simulator it can leave the software keyboard up):
        // it has a Show Trackpad toggle.
        options.tap()
        let showTrackpad = app.buttons["Show Trackpad"].firstMatch
        XCTAssertTrue(showTrackpad.waitForExistence(timeout: 5), "Show Trackpad in the options menu\n\(app.debugDescription)")
        // Without a hardware keyboard nothing on the screen holds the focus, so the menu raises no
        // software keyboard. A simulator always reports its host Mac's keyboard to the app (the screen
        // then takes the focus for its keys), so this holds on a device only.
        #if !targetEnvironment(simulator)
        if GCKeyboard.coalesced == nil {
            XCTAssertFalse(app.keyboards.firstMatch.exists, "opening the options menu raised the software keyboard")
        }
        #endif
        attach(app, "08-options-menu")

        // Its Show Trackpad toggle tucks the trackpad away (and is remembered like the notch's drag).
        showTrackpad.tap()
        XCTAssertTrue(wait(for: drawer, value: "closed"), "Show Trackpad off did not tuck it away")
        XCTAssertTrue(pad.waitForNonExistence(timeout: 5), "trackpad surface after Show Trackpad off")
        settle(app, 1)
        attach(app, "09-show-trackpad-off")
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

import XCTest

/// Leo, 2026-11-23: "the buttons atop the composer in the terminal warrant a redesign. why are those things always showing? ... and the buttons are really small."
final class TerminalKeyRowOnDemandUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testKeyRowAppearsAt44PointsOnlyWhileKeyboardIsUp() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // The key row itself: with only the harness rows tucking while the composer is in use
        // (`ComposerTuck.chrome`), so the composer's tap raises the keyboard and the row.
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle",
                                "-cmuxMobileComposerTuck", "chrome"]
        app.launch()
        defer { app.terminate() }

        let field = app.textViews["terminal.composer.field"]
        let keyboard = app.keyboards.firstMatch
        let key = app.buttons["terminal.key.keyboard"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        attach("1-keyboard-down-no-keys")
        XCTAssertFalse(keyboard.exists)
        XCTAssertFalse(key.exists && key.isHittable, "the key row is hidden on launch")

        field.tap()
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        attach("2-keyboard-up-keys-44pt")
        XCTAssertTrue(key.isHittable)
        XCTAssertGreaterThanOrEqual(key.frame.height, 44)
        XCTAssertGreaterThanOrEqual(key.frame.width, 44)
        XCTAssertEqual(key.label, "Hide Keyboard")

        key.tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        XCTAssertTrue(key.waitForNonExistence(timeout: 5) || !key.isHittable)
        attach("3-keyboard-down-again")
    }

    @MainActor
    func testKeyBarGalleryCapture() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-recovery-gallery", "keybar", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }

        for style in ["caps", "strip", "inset"] {
            let row = app.descendants(matching: .any)["keyBarGallery.style.\(style)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "missing \(style) gallery row")
        }
        attach("keybar-gallery")
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

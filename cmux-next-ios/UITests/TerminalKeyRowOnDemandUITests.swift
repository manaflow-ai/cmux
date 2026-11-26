import XCTest

/// Leo, 2026-11-23: "the buttons atop the composer in the terminal warrant a redesign. why are those things always showing? ... and the buttons are really small."
/// Leo, 2026-11-25, on the 44 pt keys that followed: "We can just bring it back to what the older size was" (28 pt).
final class TerminalKeyRowOnDemandUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testKeyRowAppearsOnlyWhileKeyboardIsUp() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-idle"]
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
        // The row's slot opens with the keyboard (0.25 s): read the key once it has.
        let open = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in key.frame.height >= 28 }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [open], timeout: 3), .completed, "the key is \(key.frame)")
        attach("2-keyboard-up-keys-28pt")
        // Classic's size again: 28 pt tall, the keyboard key 40 pt wide; its hit area is its cap.
        XCTAssertEqual(key.frame.height, 28, accuracy: 0.5)
        XCTAssertEqual(key.frame.width, 40, accuracy: 0.5)
        XCTAssertEqual(key.label, "Hide Keyboard")

        // A finger's tap in the key's middle (not `tap()`, which first asks XCUITest's hit point).
        key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "a tap on the keyboard key did not reach it")
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

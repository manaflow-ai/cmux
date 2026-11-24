import XCTest

/// Leo, 2026-11-22: "claude code has such a nice animation on startup... it's so smooth and
/// nice... I WANT US TO HAVE SHIT LIKE THAT TOO."
///
/// The new-chat entrance (`NewChatEntrance`): each look launches the app cold into a new Claude
/// workspace (`-cmux-mobile-demo kbd-empty`), so one run records the startup and the entrance of
/// every look in turn (`--arg video` makes the gallery's clips; ENTRANCE lines in the console mark
/// where each starts). In every look the composer takes typing the moment it exists, while the
/// greeting is still settling: nothing waits on the motion.
final class NewChatEntranceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testRiseTakesTypingAtOnce() { exercise("rise") }
    @MainActor func testBloomTakesTypingAtOnce() { exercise("bloom") }
    @MainActor func testFocusTakesTypingAtOnce() { exercise("focus") }

    @MainActor
    private func exercise(_ style: String) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "kbd-empty",
                                "-cmux-mobile-entrance", style]
        print("ENTRANCE \(style) launch \(Date().timeIntervalSince1970)")
        app.launch()
        defer { app.terminate() }

        let greeting = app.staticTexts["What should Claude do?"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 30), "the new chat's greeting\n\(app.debugDescription)")
        print("ENTRANCE \(style) greeting \(Date().timeIntervalSince1970)")
        let field = app.textViews["chat.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the new chat's composer\n\(app.debugDescription)")
        // Typing goes in while the entrance plays: the field is hittable and takes the text.
        XCTAssertTrue(field.isHittable, "the composer is hittable during the entrance")
        field.tap()
        field.typeText("hi")
        print("ENTRANCE \(style) typed \(Date().timeIntervalSince1970)")
        XCTAssertEqual(field.value as? String, "hi", "the composer took the typing during the entrance")
        attach(app, "\(style)-typed")
        // Rest a moment so the recording shows the settled screen with the keyboard up.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "rest")], timeout: 1.5)
        attach(app, "\(style)-rest")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

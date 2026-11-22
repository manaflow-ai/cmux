import XCTest

/// Leo, 2026-11-22: "QUESTION THE PAPERCLIP ... WHY HAVE A VOICE BUTTON IN THE TERMINAL? ... im hiding
/// this by default ... the attachments are just the most awkward shit in this case because in the common
/// case of 1, you get corner to corner tension instead of it simply being where it should be."
///
/// The composer's controls, each one checked and shot (`composer-*` attachments): + (not a
/// paperclip) first, no voice button unless turned on, the field taking the freed width, and one
/// attachment inside the field where the text starts. The reasons, with sources:
/// cmuxterm-hq docs/design/ios-composer-controls.md.
final class ComposerControlsGalleryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ arguments: [String], env: [String: String] = [:], dark: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment.merge(env) { $1 }
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-AppleInterfaceStyle", dark ? "Dark" : "Light"] + arguments
        app.launch()
        return app
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "composer-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Default: + then the field, which runs to the screen's edge; no voice, no paperclip.
    @MainActor
    func testDefaultComposerIsPlusAndField() {
        for dark in [true, false] {
            let app = launch(["-cmux-mobile-demo", "voice-terminal"], dark: dark)
            let attach = app.buttons["terminal.composer.attach"]
            XCTAssertTrue(attach.waitForExistence(timeout: 30), "the + shows\n\(app.debugDescription)")
            XCTAssertEqual(attach.label, "Add Attachment")
            XCTAssertFalse(app.buttons["terminal.composer.voice"].exists, "no voice button by default")
            let send = app.buttons["terminal.composer.send"]
            XCTAssertTrue(send.exists)
            // The field starts right after +: nothing between them.
            let gap = send.frame.minX - attach.frame.maxX
            XCTAssertGreaterThan(gap, app.frame.width * 0.55, "the field takes the width beside +: gap \(gap)")
            shoot(app, "default-\(dark ? "dark" : "light")")
            app.terminate()
        }
    }

    /// One picked photo sits inside the field, starting where the text starts, not at the
    /// screen's corner opposite send.
    @MainActor
    func testOneAttachmentSitsWhereTheTextStarts() {
        for dark in [true, false] {
            let app = launch(["-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoPhases", "oneattachment"], dark: dark)
            let tile = app.descendants(matching: .any)["terminal.attachment"].firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 40), "the attachment shows\n\(app.debugDescription)")
            sleep(4)
            // The + is a Menu: match it as any element, and never skip the placement check when it is missing.
            let attach = app.descendants(matching: .any)["terminal.composer.attach"].firstMatch
            XCTAssertTrue(attach.exists, "the + shows\n\(app.debugDescription)")
            XCTAssertGreaterThan(tile.frame.minX, attach.frame.maxX, "the tile is inside the field, right of +")
            // The composer's own text view: `textViews.firstMatch` is the terminal's, far offscreen.
            let field = app.textViews["terminal.composer.field"]
            XCTAssertTrue(field.exists, "the composer field shows\n\(app.debugDescription)")
            if field.exists {
                XCTAssertLessThan(abs(tile.frame.minX - field.frame.minX), 16, "the tile starts where the text starts")
                XCTAssertLessThan(tile.frame.maxY, field.frame.minY + 4, "the tile sits above the draft")
            }
            shoot(app, "one-attachment-\(dark ? "dark" : "light")")
            app.terminate()
        }
    }

    /// Turned on: "In Send Button" (the empty draft's send circle is voice) and "Left of Field".
    @MainActor
    func testVoiceWhenTurnedOn() {
        for placement in ["sendButton", "leading"] {
            let app = launch(["-cmux-mobile-demo", "voice-terminal", "-composer.voiceButton", placement])
            let voice = app.buttons["terminal.composer.voice"]
            XCTAssertTrue(voice.waitForExistence(timeout: 30), "\(placement): voice shows\n\(app.debugDescription)")
            XCTAssertEqual(app.buttons["terminal.composer.send"].exists, placement == "leading",
                           "\(placement): the send circle is voice only for In Send Button")
            shoot(app, "voice-\(placement)")
            app.terminate()
        }
    }

    /// The setting itself: Settings → Composer → Voice Mode → Voice Button, Off.
    @MainActor
    func testVoiceSettingIsOffByDefault() {
        let app = launch(["-cmux-mobile-tab", "settings", "-cmux-mobile-settings-page", "composer"])
        let picker = app.descendants(matching: .any)["settings.composer.voiceButton"].firstMatch
        for _ in 0..<4 where !picker.exists { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 20), "the Voice Button setting shows\n\(app.debugDescription)")
        XCTAssertTrue(picker.label.contains("Off") || (picker.value as? String)?.contains("Off") == true,
                      "off by default: \(picker.label) \(String(describing: picker.value))")
        shoot(app, "setting")
        app.terminate()
    }

    /// Leo, 2026-11-22: "chatgpt you csn swipe down inside the composer to collapse it. we need that
    /// here too". A downward drag that starts inside the focused field puts the keyboard away.
    /// Without the change the drag does nothing: a short draft's text view does not scroll.
    @MainActor
    func testSwipeDownInsideTheFieldCollapsesTheComposer() {
        let app = launch(["-cmux-mobile-demo", "voice-terminal"])
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the composer field shows\n\(app.debugDescription)")
        field.tap()
        field.typeText("hi")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "tapping the field brings up the keyboard (simulator software keyboard on)")
        shoot(app, "swipe-before")
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: 160))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.keyboards.firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(field.exists, "the field stays, collapsed")
        XCTAssertEqual(field.value as? String, "hi", "collapsing keeps the draft")
        shoot(app, "swipe-after")
        app.terminate()
    }
}
